// what
const a = [
    1,
    2,
    "deez",
    4,
    `nuts` ];
const b = {
    a: 1,
    b: 2,
    c: "deez",
    d: 4,
    e: `nuts`
};
console.log(b);
console.log(a);

console.log(JSON.stringify(b));
console.log();
console.log(JSON.stringify(b, null, 2));
console.log(JSON.stringify(a));
console.log();
