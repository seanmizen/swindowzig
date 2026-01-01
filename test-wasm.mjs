// Quick test to verify WASM exports
import { readFile } from 'fs/promises';

const wasmBytes = await readFile('./zig-out/bin/app.wasm');
const wasmModule = await WebAssembly.compile(wasmBytes);

console.log('WASM Module compiled successfully!');
console.log('\nExports:');
const exports = WebAssembly.Module.exports(wasmModule);
exports.forEach(exp => {
    console.log(`  - ${exp.name} (${exp.kind})`);
});

console.log('\nImports:');
const imports = WebAssembly.Module.imports(wasmModule);
imports.forEach(imp => {
    console.log(`  - ${imp.module}.${imp.name} (${imp.kind})`);
});
