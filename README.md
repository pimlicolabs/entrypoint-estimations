## To deploy to a chain:

1. Edit the .env and update `CHAIN_KEYS`. The format is
   `CHAIN_KEYS="RPC_URL;ETHERSCAN_API;ETHERSCAN_URL`. `ETHERSCAN_API` and
   `ETHERSCAN_URL` are optional.
2. run deploy.sh

If you want to deploy on more than one chain you can use comma separated values
in `CHAIN_KEYS`.
