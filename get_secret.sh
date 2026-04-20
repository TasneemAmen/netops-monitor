#!/bin/sh

docker exec \
  -e VAULT_ADDR=http://127.0.0.1:8200 \
  -e VAULT_TOKEN=root \
  vault \
  vault kv get -field=password secret/db > db_password.txt
