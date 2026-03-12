#!/usr/bin/env -S v

import os

os.chdir(os.dir(@FILE)) or {
	eprintln(err)
	exit(1)
}

exit_code := os.system('v -o ./v-browser ./src')
if exit_code != 0 {
	exit(exit_code)
}
