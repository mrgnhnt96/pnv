# pnv

```yaml
secret: SECRET;<encoded_data>

api:
  schema: http
  host: localhost
  port: 8080
  key: SECRET;<encoded_data>
```

```bash
pnv generate-env --key <key_value> --input env_files/local.yaml --output env_files/outputs/
```

```dotenv
# env_files/outputs/local.env
SECRET=<decoded_data>
API_SCHEMA=http
API_HOST=localhost
API_PORT=8080
API_KEY=<decoded_data>
```
