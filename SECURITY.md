# Security

Report a vulnerability privately through GitHub's "Report a vulnerability"
button on the repository's Security tab, not in a public issue. Include the
input, the command and `vera --version`.

Only the latest release is supported. `vera` compiles untrusted HDL into
code that is then built and run, so a crash on input is a bug and code
execution from input alone is a vulnerability.
