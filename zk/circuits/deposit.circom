pragma circom 2.1.9;

template DepositCommitment() {
    signal input amount;
    signal input blinding;
    signal input commitment;

    signal computed;
    computed <== amount + blinding;
    commitment === computed;
}

component main = DepositCommitment();
