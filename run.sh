#!/usr/bin/env bash

set -e

# Install openpassport and it's dependencies
git submodule init
git submodule update
if [ ! -L deps/@zk-email ]; then
    ln -s ../deps/zk-email-verify/packages deps/@zk-email
fi

# Install the Circom2 to  generate r1cs file
if [ ! -x bin/circom ]; then
    cargo install --git https://github.com/iden3/circom.git --tag v2.1.9 --bin circom --root ./
fi

# Install circom_witnesscalc crate:
# * build-circuit: creates the witness calculation description from the circom program.
# * calc-witness: calculates the witness from the witness calculation description and input signals.
if [ ! -x bin/build-circuit -o ! -x bin/calc-witness ]; then
    cargo install --git https://github.com/iden3/circom-witnesscalc.git --branch main --bin build-circuit --bin calc-witness --root ./
fi

# Install snarkjs to validate generated witness
if [ ! -d node_modules ]; then
    mkdir node_modules
fi
if [ ! -x node_modules/.bin/snarkjs ]; then
    npm install snarkjs
fi

# Generate the r1cs file
if [ ! -f register_rsa_65537_sha256.r1cs ]; then
    echo "Run circom to generate the r1cs file"
    ./bin/circom --r1cs -l deps deps/openpassport/circuits/circuits/register/register_rsa_65537_sha256.circom
fi

# All preparations are done, now we can run the tests
echo "Generate witness calculation description"
./bin/build-circuit deps/openpassport/circuits/circuits/register/register_rsa_65537_sha256.circom register_rsa_65537_sha256.bin -l deps

echo "Generate witness"
./bin/calc-witness register_rsa_65537_sha256.bin register_rsa_65537_sha256.inputs.json register_rsa_65537_sha256.wtns

echo "Validate witness correctness"
./node_modules/.bin/snarkjs wtns check register_rsa_65537_sha256.r1cs register_rsa_65537_sha256.wtns
