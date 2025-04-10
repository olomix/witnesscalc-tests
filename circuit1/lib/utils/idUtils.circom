pragma circom 2.1.1;

include "circomlib/circuits/bitify.circom";
include "circomlib/circuits/poseidon.circom";
include "circomlib/circuits/mux1.circom";
include "./safeOne.circom";

template ProfileID(){
    signal input in;
    signal input nonce;
    signal output out;

    signal hash <== Poseidon(2)([in, nonce]);
    signal genesis <== TakeNBits(27*8)(hash);

    component genesisIdParts = SplitID();
    genesisIdParts.id <== in;

    out <== NewID()(genesisIdParts.typ, genesis);

    // explicitly state that these signals are not used and it's ok
    _ <== genesisIdParts.genesis;
    _ <== genesisIdParts.checksum;
}

// Split ID into type, genesys and checksum
template SplitID() {
    signal input id;
    signal output typ;
    signal output genesis;
    signal output checksum;

    component bs = Num2Bits(248);
    bs.in <== id;

    // checksum bytes are swapped in ID. 31-th byte is first and 30-th is second.
    component checksumBits = Bits2Num(16);
    for (var i = 0; i < 16; i++) {
        checksumBits.in[i] <== bs.out[29 * 8 + i];
    }
    checksum <== checksumBits.out;

    component genesisBits = Bits2Num(216);
    for (var i = 0; i < 216; i++) {
        genesisBits.in[i] <== bs.out[i + 16];
    }
    genesis <== genesisBits.out;

    component typBits = Bits2Num(16);
    for (var i = 0; i < 16; i++) {
        typBits.in[i] <== bs.out[i];
    }
    typ <== typBits.out;

    // explicitly state that some of these signals are not used and it's ok
    for (var i=0; i<248; i++) {
        _ <== bs.out[i];
    }
}

template NewID() {
    signal input typ;
    signal input genesis;
    signal output out;

    signal checksum <== CalculateIdChecksum()(typ, genesis);

    out <== GatherID()(typ, genesis, checksum);
}

// return 31-byte ID made up from type, genesis and checksum
template GatherID() {
    signal input typ;
    signal input genesis;
    signal input checksum;
    signal output out;

    component idBits = Bits2Num(31*8);

    component checksumBits = Num2Bits(2*8);
    checksumBits.in <== checksum;
    for (var i = 0; i < 16; i++) {
        idBits.in[29*8+i] <== checksumBits.out[i];
    }

    component genesisBits = Num2Bits(27*8);
    genesisBits.in <== genesis;
    for (var i = 0; i < 27 * 8; i++) {
        idBits.in[2*8+i] <== genesisBits.out[i];
    }

    component typBits = Num2Bits(2*8);
    typBits.in <== typ;
    for (var i = 0; i < 2 * 8; i++) {
        idBits.in[i] <== typBits.out[i];
    }

    out <== idBits.out;
}

// Take least significant n bits
template TakeNBits(n) {
    signal input in;
    signal output out;

    assert(n <= 254);

    // We take only n least significant bits from 254 bit number.
    component bits = Num2Bits_strict();
    bits.in <== in;

    component outBits = Bits2Num(n);
    for (var i = 0; i < n; i++) {
        outBits.in[i] <== bits.out[i];
    }
    out <== outBits.out;

    // explicitly state that these signals are not used and it's ok
    for (var i=n; i<254; i++) {
        _ <== bits.out[i];
    }
}

template CalculateIdChecksum() {
    signal input typ; // 2 bytes
    signal input genesis; // 27 bytes
    signal output out;

    signal sum[30];
    var k = 0;
    sum[0] <== 0;

    component typBits = Num2Bits(16);
    typBits.in <== typ;
    for (var i = 0; i < 16; i = i + 8) {
        var lc1 = 0;
        var e2 = 1;
        for (var j = 0; j < 8; j++) {
            lc1 += typBits.out[i + j] * e2;
            e2 = e2 + e2;
        }
        sum[k+1] <== sum[k] + lc1;
        k++;
    }

    component genesisBits = Num2Bits(27*8);
    genesisBits.in <== genesis;
    for (var i = 0; i < 27*8; i = i + 8) {
        var lc1 = 0;
        var e2 = 1;
        for (var j = 0; j < 8; j++) {
            lc1 += genesisBits.out[i + j] * e2;
            e2 = e2 + e2;
        }
        sum[k+1] <== sum[k] + lc1;
        k++;
    }

    // no need to cut last 16 bits of sum, because max value of sum is 255*29 = 7395 = 0x1CE3 - 16 bits
    out <== sum[k];
}

// SelectProfile `out` output signal will be assigned with user profile,
// unless nonce == 0, in which case profile will be assigned with `in` id
template SelectProfile() {
    signal input in;
    signal input nonce;

    signal output out;

    signal isNonceZero <== IsZero()(nonce);
    signal calcProfile <== ProfileID()(in, nonce);

    out <== Mux1()(
        [calcProfile, in],
        isNonceZero
    );
}

template cutId() {
	signal input in;
	signal output out;

	signal idBits[248] <== Num2Bits(248)(in);

	component cut = Bits2Num(216);
	for (var i=16; i<248-16; i++) {
		cut.in[i-16] <== idBits[i];
	}
	out <== cut.out;
}

template cutState() {
	signal input in;
	signal output out;

	signal stateBits[254] <== Num2Bits_strict()(in);

	component cut = Bits2Num(216);
	// two most significant bits of 256-bit number are always 0, because we have 254-bit prime field
	for (var i=0; i<216-2; i++) {
		cut.in[i] <== stateBits[i+16+16+8];
	}
	cut.in[214] <== 0;
	cut.in[215] <== 0;
	out <== cut.out;
}

// getIdenState calculates the Identity state out of the claims tree root,
// revocations tree root and roots tree root.
template getIdenState() {
	signal input claimsTreeRoot;
	signal input revTreeRoot;
	signal input rootsTreeRoot;

	signal output idenState <== Poseidon(3)([
	    claimsTreeRoot,
	    revTreeRoot,
	    rootsTreeRoot
	]);
}
