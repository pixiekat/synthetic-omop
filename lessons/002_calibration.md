# Lesson 002: Calibration, or Why We Estimate Disorders *Jointly*

| | |
|---|---|
| **Course level** | First to second year undergraduate |
| **Estimated time** | 75–90 minutes (lecture + lab) |
| **Prerequisites** | Lesson 001; fractions and percentages; reading a simple table. No prior statistics course needed. |
| **Project files** | `services/calibration/estimate_joint.py`, `services/calibration/config.json`, `services/synthea/modules/concurrent_disorders.json` |
| **Previous lesson** | 001: The Pipeline from the Inside |

> **About the numbers in this lesson:** every worked example uses **made-up, illustrative
> numbers** chosen to make the arithmetic clear. None of them are NSDUH estimates. Real
> estimates come from running the calibration step on the real data file.

## Learning objectives

By the end of this lesson you should be able to:

1. Explain what **calibration** means for a synthetic population.
2. Explain what a **survey weight** is, and why unweighted counts can mislead.
3. Tell the difference between **marginal**, **joint** and **conditional** probabilities, using a 2×2 table.
4. Show, with numbers, why **multiplying two prevalences** gets co-occurrence wrong.
5. Explain why we estimate **within strata** (age × sex), and what goes wrong in **sparse cells**.
6. Explain why **unknown answers** must be handled explicitly, not counted as "no".
7. Estimate how much **random noise** to expect in a synthetic population of a given size.
8. List what a cross-sectional survey **cannot** tell us.

---

## 1. What "calibration" means here

Synthea already makes realistic-*looking* patients. Out of the box, though, nothing guarantees
that the share of people with *both* a mental health disorder (MHD) and a substance use disorder
(SUD) matches the real world.

**Calibration** means tuning the synthetic population so its frequencies match a trusted
external source. Here that source is the **National Survey on Drug Use and Health (NSDUH)**.

The pipeline splits this into two halves:

```
 NSDUH survey file ──▶ estimate_joint.py ──▶ joint_probabilities.json ──▶ Synthea module
     (data)            (Lesson 002: here)        (the numbers)            (Lesson 001's "generate")
```

---

## 2. Survey weights: not everyone counts the same

NSDUH interviews tens of thousands of people, but not as a perfectly even slice of the country.
Some groups are deliberately **oversampled**, interviewed at higher rates than their share of the
population, so there are enough of them to study. Young adults are a common example.

To correct for this, each respondent carries an **analysis weight**: roughly, *the number of
people in the real population that this one respondent stands in for.*

### Worked example A: weights change the answer

A toy survey of 10 adults, each with a weight:

| ID | Age | MHD | SUD | Weight |
|---|---|---|---|---|
| 1 | 18–25 | yes | yes | 3,000 |
| 2 | 18–25 | no | yes | 2,000 |
| 3 | 18–25 | yes | no | 2,500 |
| 4 | 18–25 | no | no | 4,000 |
| 5 | 18–25 | no | no | 3,500 |
| 6 | 26+ | yes | no | 9,000 |
| 7 | 26+ | no | no | 12,000 |
| 8 | 26+ | no | no | 11,000 |
| 9 | 26+ | yes | yes | 6,000 |
| 10 | 26+ | no | no | 10,000 |

Half the respondents are 18–25, but they carry only 15,000 of the 63,000 total weight (about
24%). Young adults were oversampled.

**Share with *both* disorders:**

- **Unweighted** (just counting people): 2 out of 10 = **20%**
- **Weighted** (respondents 1 and 9): (3,000 + 6,000) ÷ 63,000 = 9,000 ÷ 63,000 ≈ **14.3%**

Same data, different answers. The unweighted figure over-represents young adults. The weighted
one estimates the *population*. In `estimate_joint.py`, this is the line doing the work:

```python
totals = df.groupby("cell")[weight_var].sum()   # add up WEIGHTS per cell, not people
```

---

## 3. Marginal, joint and conditional probabilities

A 2×2 table is the core idea of this whole lesson. These **illustrative** numbers describe a
population of adults:

|  | **SUD: yes** | **SUD: no** | **Row total** |
|---|---|---|---|
| **MHD: yes** | **7%** (both) | 13% (MHD only) | **20%** |
| **MHD: no** | 8% (SUD only) | 72% (neither) | **80%** |
| **Column total** | **15%** | 85% | 100% |

- **Marginal** probabilities sit in the margins: P(MHD) = 20%, P(SUD) = 15%. Each looks at one
  disorder and ignores the other.
- **Joint** probabilities are the four inner cells: P(MHD **and** SUD) = 7%, and so on. They
  always sum to 100%.
- **Conditional** probabilities answer "*given* one thing, how likely is the other?":
  - P(SUD | MHD) = 7% ÷ 20% = **35%**. Among people with MHD, 35% also have SUD.
  - P(SUD | no MHD) = 8% ÷ 80% = **10%**.

That jump from 10% to 35% is the whole story. The two disorders are **associated**: having one
makes the other more likely.

### Worked example B: why multiplying prevalences fails

The shortcut people reach for is:

> P(both) = P(MHD) × P(SUD) = 0.20 × 0.15 = **0.03 = 3%**

But the table says **7%**. The shortcut is only valid when the two things are
**independent**, meaning one tells you nothing about the other. Here they plainly aren't
(35% vs 10%).

What that means for a synthetic population of 1,000 adults:

| Method | Expected "both" patients |
|---|---|
| Independent draws (multiply) | 1,000 × 0.03 = **30** |
| Joint draw (this project) | 1,000 × 0.07 = **70** |

The shortcut would **understate concurrent disorders by more than half**, and those are exactly
the patients this project exists to study. That's why the module draws **one** profile from
four options, and why its remarks say *"NEVER replace this with two independent draws."*

> **Stretch:** one standard way to summarise association is the **odds ratio**. For this table
> it's (7 × 72) ÷ (13 × 8) ≈ **4.8**. Under independence it would be 1.

---

## 4. Strata: one table per group

Rates differ across groups. For example, SUD is typically more common among younger adults. If
we computed one table for *all* adults and applied it to everyone, 22-year-olds and 70-year-olds
would get the same probabilities. That's wrong at both ends.

So `estimate_joint.py` builds a **separate four-cell table for each stratum** (age band × sex),
and the Synthea module has one `complex_transition` entry per stratum.

### Worked example C: strata, and an empty cell

Splitting the toy survey from example A by age (weighted, within each group):

| Stratum | Respondents | Neither | MHD only | SUD only | Both |
|---|---|---|---|---|---|
| 18–25 | 5 | 50.0% | 16.7% | 13.3% | 20.0% |
| 26+ | 5 | 68.8% | 18.8% | **0%** | 12.5% |

The two age groups look very different, which is the reason we stratify. But look at the 26+
row: **nobody** in our tiny sample was "SUD only," so the estimate is **0%**. If we copied that
into the module, Synthea would *never* generate an older adult with SUD alone. That's absurd;
it's an artefact of sample size.

That's the **sparse cell problem**: the more finely you slice the data, the fewer respondents
land in each cell, and the less you can trust the estimates. The calibration config guards
against it:

```json
"min_unweighted_n": 50
```

If any cell in a stratum has fewer than 50 actual respondents, the script **pools** that stratum
(here, combining both sexes within the age band) and records that it did so in
`collapsed_from`. This is a classic **trade-off**:

| Finer strata | Coarser strata |
|---|---|
| ✅ Captures real differences between groups | ✅ More respondents per cell, so steadier estimates |
| ❌ Small cells, noisy or zero estimates | ❌ Blurs real differences together |

There's no perfect setting. You pick a threshold, apply it consistently, and **document it**.

---

## 5. Unknown answers are not "no"

Survey files use special codes for *refused*, *don't know*, *blank* and *legitimate skip*
(question not asked). In the toy survey, imagine an 11th respondent who **refused** the
mental-health questions.

The tempting mistake is to count them as "no MHD." But we don't *know* that, and people who
decline sensitive questions may differ systematically from those who answer. Silently recoding
them as "no" **biases every estimate downward**.

So the script recodes unknowns to an explicit "missing" (`NA`), drops them, and **reports how
many it dropped**:

```python
out = pd.Series(pd.NA, index=series.index, dtype="boolean")   # start as "unknown"
out[series.isin(spec["present_values"])] = True               # only listed codes become yes
out[series.isin(spec["absent_values"])] = False               # only listed codes become no
```

The printed drop percentage goes in `docs/run-log.md`. If it's large, that's a limitation worth
writing up.

---

## 6. From probabilities to patients: expect noise

The module turns each stratum's four probabilities into a **random draw**, like rolling a
weighted four-sided die once per person. Random draws don't hit the target exactly. How far off
should you expect to be?

For a proportion *p* in a group of *n* people, the typical random wobble (the **standard error**) is:

$$
\text{SE} = \sqrt{\frac{p(1-p)}{n}}
$$

Roughly 95% of the time, the observed share falls within **about 2 × SE** of the target.

### Worked example D: how big does the population need to be?

Target "both" = 7%:

| People in the stratum (*n*) | 95% wobble (≈ 1.96 × SE) | Observed share will usually fall within… |
|---|---|---|
| 130 | ±4.4 points | **2.6% to 11.4%** |
| 1,300 | ±1.4 points | **5.6% to 8.4%** |

Ten times the people buys roughly a **√10 ≈ 3×** tighter result. That's why the guide says to
validate at **10,000 patients** before concluding the module is wrong, rather than at 1,000.

### Worked example E: checking our own pilot run

The pilot used **placeholder** probabilities of 0.25 for each cell, in one stratum (women 35–49).
The run produced **35 MHD only, 35 SUD only, 28 both**: 98 people in the three non-"neither" cells.

- If 98 people make up 75% of the stratum, the stratum holds about 98 ÷ 0.75 ≈ **131** people.
- The expected count per cell is 131 × 0.25 ≈ **33**.
- The typical wobble in a count is √(131 × 0.25 × 0.75) ≈ **5**.

All three observed counts (35, 35, 28) are within about one wobble of 33. The draw behaves
exactly as random sampling predicts, so nothing is broken. That's what validation means: comparing
what you got against what chance allows, not demanding an exact match.

---

## 7. What the survey *can't* tell us

Calibration matches **frequencies**. It doesn't make the data clinically true. Keep these limits
in view, and say them out loud in any write-up:

| Limitation | Why it matters |
|---|---|
| **Cross-sectional** | Each person is surveyed once. We learn "who has what, now," not when it started or how it changes. Timing in the module is a **simulation assumption** (A-001). |
| **Survey definitions, not diagnoses** | "Any mental illness" is a survey construct. Turning it into "major depressive disorder" is an **assumption** (A-002), not a finding. |
| **Who was surveyed** | Civilian, noninstitutionalized population. People in hospitals, prisons or residential treatment aren't represented. |
| **Point estimates only** | Our script doesn't compute **confidence intervals**, which need the survey's design variables (strata and clusters). That's a future upgrade. |

---

## Lab

### Part 1: by hand (pencil or spreadsheet)

Using the toy survey table in section 2:

1. Compute the **weighted** share for each of the four cells (all ages together).
2. Compute weighted P(MHD) and P(SUD), then the "independence" guess P(MHD) × P(SUD).
3. Compare your guess with the real weighted share for "both." Which is larger? By how much?

### Part 2: check yourself with pandas

Save this as `lab_002.py` somewhere outside the project's `data/` folder and run it with
`python3 lab_002.py`. Answers are in the comments, so try Part 1 first.

```python
"""
lab_002.py: weighted joint distribution on the toy survey from Lesson 002.

Teaching goals:
  * see weighted vs unweighted shares side by side
  * see the independence shortcut fail
  * see a sparse (zero) cell appear when you stratify
"""
import pandas as pd

# ---------------------------------------------------------------------------
# Toy survey. mhd/sud: 1 = yes, 0 = no, None = refused/unknown.
# Respondent 11 refused the MHD question, to practise handling unknowns.
# ---------------------------------------------------------------------------
df = pd.DataFrame(
    [
        (1,  "18-25", 1,    1, 3000),
        (2,  "18-25", 0,    1, 2000),
        (3,  "18-25", 1,    0, 2500),
        (4,  "18-25", 0,    0, 4000),
        (5,  "18-25", 0,    0, 3500),
        (6,  "26+",   1,    0, 9000),
        (7,  "26+",   0,    0, 12000),
        (8,  "26+",   0,    0, 11000),
        (9,  "26+",   1,    1, 6000),
        (10, "26+",   0,    0, 10000),
        (11, "26+",   None, 0, 8000),
    ],
    columns=["id", "age", "mhd", "sud", "weight"],
)

# --- Step 1: drop unknowns EXPLICITLY, and say how many --------------------
before = len(df)
df = df.dropna(subset=["mhd", "sud"])
print(f"Dropped {before - len(df)} respondent(s) with unknown status")   # → 1

# --- Step 2: label each person with one of the four cells -------------------
def cell(row):
    """Map an (mhd, sud) pair to a cell name."""
    return {
        (0, 0): "neither",
        (1, 0): "mhd_only",
        (0, 1): "sud_only",
        (1, 1): "both",
    }[(int(row.mhd), int(row.sud))]

df["cell"] = df.apply(cell, axis=1)

# --- Step 3: unweighted vs weighted shares -----------------------------------
unweighted = df["cell"].value_counts(normalize=True)
weighted = df.groupby("cell")["weight"].sum() / df["weight"].sum()
print(pd.DataFrame({"unweighted": unweighted, "weighted": weighted}).round(3))
# both: unweighted 0.200, weighted 0.143

# --- Step 4: the independence shortcut ---------------------------------------
total = df["weight"].sum()
p_mhd = df.loc[df.mhd == 1, "weight"].sum() / total   # ≈ 0.325
p_sud = df.loc[df.sud == 1, "weight"].sum() / total   # ≈ 0.175
print(f"Independence guess for 'both': {p_mhd * p_sud:.3f}")             # ≈ 0.057
print(f"Actual weighted 'both':        {weighted['both']:.3f}")          # ≈ 0.143

# --- Step 5: stratify by age and look for empty cells ------------------------
for age, group in df.groupby("age"):
    shares = (group.groupby("cell")["weight"].sum() / group["weight"].sum())
    shares = shares.reindex(["neither", "mhd_only", "sud_only", "both"], fill_value=0)
    print(age, shares.round(3).to_dict())
# 26+ has sud_only = 0.0, which is a sparse cell!
```

### Part 3: reflect

In two or three sentences: if you fed the 26+ row from Part 2 straight into the Synthea module,
what would the synthetic population look like, and how does `min_unweighted_n` prevent it?

---

## Check your understanding

1. A respondent's weight is 4,000. In plain words, what does that mean?
2. P(MHD) = 25% and P(SUD) = 10%. A colleague says P(both) must be 2.5%. What do you need to
   know before agreeing?
3. Why does the module draw **one** of four profiles instead of drawing MHD and SUD separately?
4. In a stratum of 60 people, the target for "both" is 10% but you observe 13%. Is the module
   broken?
5. Why is it a mistake to treat "refused" as "no"?
6. Name two things NSDUH can't tell us that the Synthea module still needs.

<details>
<summary><strong>Answers</strong></summary>

1. That respondent stands in for roughly **4,000 people** in the population.
2. Whether the two disorders are **independent**. Multiplying is only valid then, and MHD and
   SUD are typically **associated**, so the real joint share is usually higher.
3. Separate draws would treat the disorders as independent and **understate co-occurrence**. One
   joint draw preserves the real relationship between them.
4. **Probably not.** SE = √(0.10 × 0.90 ÷ 60) ≈ 0.039, so the 95% range is about 2% to 18%,
   and 13% falls well within it. Check again at a larger population before suspecting a bug.
5. It assumes an answer we don't have. People who decline sensitive questions may differ from
   those who answer, so it **biases estimates** (here, downward).
6. Any two of: **timing** (onset, relapse, visit patterns); **specific diagnoses** (survey
   categories aren't diagnosis codes); **treatment histories**; **institutionalized populations**.

</details>

---

## Key terms

| Term | One-line definition |
|---|---|
| **Calibration** | Tuning a synthetic population so its frequencies match a trusted source |
| **Survey weight** | Roughly how many people in the population one respondent represents |
| **Oversampling** | Deliberately interviewing a group at a higher rate than its population share |
| **Marginal probability** | The chance of one thing, ignoring the other (a table's margins) |
| **Joint probability** | The chance of two things together (a table's inner cells) |
| **Conditional probability** | The chance of one thing *given* another: P(A \| B) = P(A and B) ÷ P(B) |
| **Independence** | One event tells you nothing about the other, so P(A and B) = P(A) × P(B) |
| **Odds ratio** | A summary of association between two yes/no variables; 1 means none |
| **Stratum** | A subgroup (e.g. women aged 35–49) analysed separately |
| **Sparse cell** | A table cell with too few respondents to estimate reliably |
| **Standard error** | The typical size of random wobble in an estimate |
| **Cross-sectional** | Measured at one point in time, with no follow-up |

---

## Further reading

- **OpenIntro Statistics**, chapter 3 (probability, including conditional probability and
  independence). Free textbook: <https://www.openintro.org/book/os/>
- **Seeing Theory** (Brown University): interactive visuals for probability and sampling
  noise: <https://seeing-theory.brown.edu/>
- **NSDUH Data Users' Guide**, the sections on weighting and variance estimation. You already
  have it in `data/source/nsduh/2024/`.
- **Thomas Lumley, *Complex Surveys: A Guide to Analysis Using R***: the next step, when you
  add confidence intervals using the survey design.
