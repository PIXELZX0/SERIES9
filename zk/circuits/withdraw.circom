pragma circom 2.1.9;

template WithdrawNullifier() {
    signal input secret;
    signal input amount;
    signal input root;
    signal input nullifier;

    signal computed;
    computed <== secret + amount + root;
    nullifier === computed;
}

component main = WithdrawNullifier();
