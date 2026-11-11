"""
estimate_joint.py

Estimate the weighted JOINT distribution of mental health disorder (MHD)
and substance use disorder (SUD) within age x sex strata, from the NSDUH
public use file.

Output: joint_probabilities.json, with one entry per stratum:
  {
    "stratum": {"age": "35-49", "sex": "F"},
    "unweighted_n": 4123,
    "collapsed_from": null,
    "p": {"neither": 0.71, "mhd_only": 0.19, "sud_only": 0.04, "both": 0.06}
  }

IMPORTANT LIMITATIONS (also documented in docs/assumptions.md):
  * POINT ESTIMATES ONLY. This script applies the analysis weight but does
    not use the survey design (strata/PSU) to compute variance. For
    confidence intervals use R's `survey` package or Python's `samplics`
    with the design variables listed in the Data Users' Guide.
  * Survey categories stay survey categories. "Any mental illness" is
    NOT turned into a specific diagnosis here. That happens, as an explicit
    assumption, in the Synthea module (Step 5).

@see https://www.samhsa.gov/data/data-we-collect/nsduh-national-survey-drug-use-and-health
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import pandas as pd

# The four cells we always estimate together. Order matters: it's the order
# the Synthea module's distributed transitions are written in.
CELLS = ("neither", "mhd_only", "sud_only", "both")


def load_config(path: str) -> dict:
    """
    Load the JSON config that maps NSDUH variables to our definitions.

    @param path  Path to config.json.
    @return      Parsed config dictionary.
    """
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def load_nsduh(cfg: dict) -> pd.DataFrame:
    """
    Read the NSDUH file, keeping only the columns we need (lower memory use).

    @param cfg  Config dict (uses input_file, input_format, and variable names).
    @return     DataFrame restricted to the needed columns.
    """
    cols = [cfg["weight_var"], cfg["age_var"], cfg["sex_var"],
            cfg["mhd"]["var"], cfg["sud"]["var"]]
    fmt = cfg.get("input_format", "tsv")

    if fmt == "tsv":
        return pd.read_csv(cfg["input_file"], sep="\t", usecols=cols, low_memory=False)
    if fmt == "stata":
        return pd.read_stata(cfg["input_file"], columns=cols, convert_categoricals=False)
    raise ValueError(f"Unsupported input_format: {fmt}")


def recode_flag(series: pd.Series, spec: dict) -> pd.Series:
    """
    Turn a raw NSDUH variable into True / False / NA.

    Codes not listed in present_values or absent_values (missing, refused,
    legitimate skip, etc.) become NA EXPLICITLY, so they are never silently
    counted as "absent".

    @param series  Raw column.
    @param spec    {"present_values": [...], "absent_values": [...]}
    @return        Nullable boolean Series.
    """
    out = pd.Series(pd.NA, index=series.index, dtype="boolean")
    out[series.isin(spec["present_values"])] = True
    out[series.isin(spec["absent_values"])] = False
    return out


def assign_cell(mhd: pd.Series, sud: pd.Series) -> pd.Series:
    """
    Combine the two flags into one of the four CELLS.

    @param mhd  Nullable boolean MHD flag.
    @param sud  Nullable boolean SUD flag.
    @return     Categorical Series of cell labels (NA if either flag is NA).
    """
    cell = pd.Series(pd.NA, index=mhd.index, dtype="object")
    cell[(~mhd) & (~sud)] = "neither"
    cell[(mhd) & (~sud)] = "mhd_only"
    cell[(~mhd) & (sud)] = "sud_only"
    cell[(mhd) & (sud)] = "both"
    return cell


def weighted_joint(df: pd.DataFrame, weight_var: str) -> dict:
    """
    Weighted proportion of each cell within one stratum.

    @param df          Rows for a single stratum (cell column already set).
    @param weight_var  Name of the analysis-weight column.
    @return            {cell: proportion}, summing to 1.0.
    """
    totals = df.groupby("cell")[weight_var].sum()
    grand = totals.sum()
    return {c: round(float(totals.get(c, 0.0) / grand), 6) for c in CELLS}


def main() -> None:
    """Entry point: load → recode → stratify → estimate → collapse sparse → write."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True)
    args = parser.parse_args()
    cfg = load_config(args.config)

    df = load_nsduh(cfg)

    # Adults only. CATAG6 = 1 is ages 12-17 (verify in the codebook).
    flt = cfg["adult_filter"]
    df = df[~df[flt["var"]].isin(flt["exclude_values"])].copy()

    # Explicit recoding: unknowns become NA, then are dropped and COUNTED.
    df["mhd"] = recode_flag(df[cfg["mhd"]["var"]], cfg["mhd"])
    df["sud"] = recode_flag(df[cfg["sud"]["var"]], cfg["sud"])
    n_before = len(df)
    df = df.dropna(subset=["mhd", "sud"])
    print(f"Dropped {n_before - len(df)} rows with unknown MHD/SUD status "
          f"({(n_before - len(df)) / n_before:.1%}). Record this in run-log.md.")

    df["cell"] = assign_cell(df["mhd"], df["sud"])
    df["age"] = df[cfg["age_var"]].astype(str).map(cfg["age_groups"])
    df["sex"] = df[cfg["sex_var"]].astype(str).map(cfg["sex_labels"])

    results = []
    for (age, sex), grp in df.groupby(["age", "sex"]):
        entry = {"stratum": {"age": age, "sex": sex},
                 "unweighted_n": int(len(grp)),
                 "collapsed_from": None,
                 "p": weighted_joint(grp, cfg["weight_var"])}

        # Sparse-cell handling: if any cell has too few respondents, fall
        # back to the age-only stratum (both sexes pooled). The "collapsed_from"
        # field records this so it shows up in validation.
        cell_counts = grp["cell"].value_counts()
        if (cell_counts.reindex(CELLS, fill_value=0) < cfg["min_unweighted_n"]).any():
            pooled = df[df["age"] == age]
            entry["p"] = weighted_joint(pooled, cfg["weight_var"])
            entry["collapsed_from"] = f"age={age} (sexes pooled)"

        results.append(entry)

    out = {
        "source": "NSDUH 2024 PUF",
        "definitions": {"mhd": cfg["mhd"]["definition"], "sud": cfg["sud"]["definition"]},
        "note": "Weighted point estimates; no design-based variance. See docs/assumptions.md.",
        "strata": results,
    }
    Path(cfg["output_file"]).write_text(json.dumps(out, indent=2), encoding="utf-8")
    print(f"Wrote {len(results)} strata → {cfg['output_file']}")


if __name__ == "__main__":
    main()
