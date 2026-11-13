# record-opened-url.sh

The Linux URL handler of the `32-external-links` scenario. The scenario writes a desktop file that names it in place of a
browser, so GIO runs it with each address the app asked the system to open, and the scenario can check the handoff from
outside the app.

Invoked as `record-opened-url.sh <record file> <address>`, with the record file the scenario keeps the addresses in. It
appends the address as one line to the record file, and exits 2 with a usage line when it is not given two arguments.
