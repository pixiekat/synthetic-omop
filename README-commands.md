# Useful Commands

## Backup the database. 

```bash
docker compose exec -T omop-db sh -c 'pg_dump -U "$POSTGRES_USER" -Fc "$POSTGRES_DB"' > backups/<filename>.dump
```
