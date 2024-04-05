#!/bin/bash

# set -e

source .env

# Split the CHAIN_KEYS variable by comma, then iterate over each pair
IFS=',' read -r -a pairs <<< "$CHAIN_KEYS"
for pair in "${pairs[@]}"; do
  # Split each pair by '='
  
  IFS=';' read -r -a kv <<< "$pair"
  RPC_URL="${kv[0]}"
  ETHERSCAN_KEY="${kv[1]}"
  ETHERSCAN_URL="${kv[2]}"

  echo "Deploying to $RPC_URL, verifying with $ETHERSCAN_URL using key $ETHERSCAN_KEY"

  forge script script/PimlicoEntryPointSimulations.s.sol:PimlicoEntryPointSimulationsScript \
    --rpc-url "$RPC_URL" \
    --account pimlico-utility \
    --broadcast \
    -vvvv

  forge verify-contract 0x82F92A31dd69e23f71E3e1674450979Efb434269 src/PimlicoEntryPointSimulations.sol:PimlicoEntryPointSimulations \
    --verifier-url "$ETHERSCAN_URL" \
    --etherscan-api-key "$ETHERSCAN_KEY"

  forge verify-contract 0x1672E79fa2FA04D5675c264f2581B073a850BF63 src/EntryPointSimulations.sol:EntryPointSimulations \
    --verifier-url "$ETHERSCAN_URL" \
    --etherscan-api-key "$ETHERSCAN_KEY"


  # Use CHAIN and KEY as needed
  # Example: echo "https://$CHAIN.rpc.thirdweb.com/$KEY"
  
  # Insert your deployment and verification commands here
done

