#!/usr/bin/env bash

set -e

# Install openpassport and it's dependencies
git submodule init
git submodule update
if [ ! -L deps/@zk-email ]; then
    ln -s ../deps/zk-email-verify/packages deps/@zk-email
fi

if [ ! -d deps/zk-email-verify/packages/circuits/node_modules ]; then
	echo "Install zk-email-verify deps"
	pushd deps/zk-email-verify/packages/circuits
	mkdir node_modules
	npm install
	popd
fi

# Install the Circom2 to  generate r1cs file
if [ ! -x bin/circom ]; then
    cargo install --git https://github.com/iden3/circom.git --tag v2.1.9 --bin circom --root ./
fi

# Install circom_witnesscalc crate:
# * build-circuit: creates the witness calculation description from the circom program.
# * calc-witness: calculates the witness from the witness calculation description and input signals.
if [ ! -x bin/build-circuit -o ! -x bin/calc-witness ]; then
	echo "Install circom-witnesscalc binaries into ./bin directory"
    cargo install --git https://github.com/iden3/circom-witnesscalc.git --branch main --bin build-circuit --bin calc-witness --root ./
fi

# Install snarkjs to validate generated witness
if [ ! -d node_modules ]; then
    mkdir node_modules
fi
if [ ! -x node_modules/.bin/snarkjs ]; then
    npm install snarkjs
fi

if [ ! -d workdir/zk-email-verify ]; then
	mkdir -p workdir/zk-email-verify
fi
cd workdir/zk-email-verify

# Generate the r1cs file
if [ ! -f email-verifier-test.r1cs ]; then
    echo "Run circom to generate the r1cs file"
    ../../bin/circom --r1cs -l ../../deps/zk-email-verify/node_modules ../../deps/zk-email-verify/packages/circuits/tests/test-circuits/email-verifier-test.circom
fi

# All preparations are done, now we can run the tests
echo "Generate witness calculation description"
ulimit -s 65520
../../bin/build-circuit ../../deps/zk-email-verify/packages/circuits/tests/test-circuits/email-verifier-test.circom email-verifier-test.wcd -l ../../deps/zk-email-verify/node_modules


# Create a zkey for proof generation
if [ ! -f email-verifier-test.zkey ]; then
	echo "Generate ZKEY"

	ptau_url="https://storage.googleapis.com/zkevm/ptau/powersOfTau28_hez_final_21.ptau"
	ptau_path="../../$(basename $ptau_url)"
	if [ ! -f "$ptau_path" ]; then
		echo "Downloading $ptau_url to $ptau_path"
		curl -L "$ptau_url" -o "$ptau_path"
	fi
	
	../../node_modules/.bin/snarkjs groth16 setup email-verifier-test.r1cs "$ptau_path" email-verifier-test_0000.zkey
	ENTROPY1=$(head -c 64 /dev/urandom | od -An -tx1 -v | tr -d ' \n')
	../../node_modules/.bin/snarkjs zkey contribute email-verifier-test_0000.zkey email-verifier-test.zkey --name="1st Contribution" -v -e="$ENTROPY1"
	../../node_modules/.bin/snarkjs zkey verify email-verifier-test.r1cs "$ptau_path" email-verifier-test.zkey
fi

if [ ! -f email-verifier-test_verification_key.json ]; then
	echo "Export verification key"
	../../node_modules/.bin/snarkjs zkey export verificationkey email-verifier-test.zkey email-verifier-test_verification_key.json
fi

echo "Generate witness"
time ../../bin/calc-witness email-verifier-test.wcd ../../email_verifier_inputs.json email-verifier-test.wtns

echo "Validate witness correctness"
time ../../node_modules/.bin/snarkjs wtns check email-verifier-test.r1cs email-verifier-test.wtns

echo "Generate proof"
time ../../node_modules/.bin/snarkjs groth16 prove email-verifier-test.zkey email-verifier-test.wtns email-verifier-test_proof.json email-verifier-test_public.json

echo "Verify proof"
time ../../node_modules/.bin/snarkjs groth16 verify email-verifier-test_verification_key.json email-verifier-test_public.json email-verifier-test_proof.json
