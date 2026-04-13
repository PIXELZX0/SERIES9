const vectors = {
  deposit: {
    amount: '1000000000000000000',
    blinding: '123456789',
    commitment: '1000000000123456789'
  },
  withdraw: {
    secret: '42',
    amount: '1000000000000000000',
    root: '7',
    nullifier: '1000000000000000049'
  }
};

console.log(JSON.stringify(vectors, null, 2));
