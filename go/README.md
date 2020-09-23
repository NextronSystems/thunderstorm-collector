# THOR Thunderstorm Collector Executable

The Thunderstorm collector executable is an open-source tool written in Go to upload files to THOR Thunderstorm.
A Makefile has been added to allow for simplified creation of executables. The generated executables are statically linked, and no further dependencies on
the target systems exist.

### Build requirements
- Go version 1.12 or higher
- make

### Build
Install golang package dependencies:
```
go get -d github.com/spf13/pflag
go get -d gopkg.in/yaml.v3
```
Build executables:
```
make
```

If you want to build executables for other platform / architecture combinations than those built in the default configuration, use:
```
make bin/<arch>-<os>-thunderstorm-collector
```

A full list of architectures and platforms that can be used is listed at the start of the Makefile. Note that not all combinations are supported.


### Execution examples

Note: The following examples use the amd64-linux-thunderstorm-collector, replace
the name of the executable with the one you are using. 

Upload all files that are smaller than 500 MB to thunderstorm.test using HTTP, with 10 Threads in parallel:
```
./amd64-linux-thunderstorm-collector -s http://thunderstorm.test:8080 -r 10 -m 500
```

Upload all files that are smaller than 500 MB and changed in the last 10 days to thunderstorm.test using HTTPS:
```
./amd64-linux-thunderstorm-collector -s https://thunderstorm.test:8080 -a 10 -m 500
```

Upload all files from a specific directory:
```
./amd64-linux-thunderstorm-collector -s http://thunderstorm.test:8080 -p /path/to/directory
```

Upload using a proxy:
```
./amd64-linux-thunderstorm-collector -s http://thunderstorm.test:8080 --http-proxy http://username@password:proxy.test/
```

Upload synchronously and write the results to a log file:
```
./amd64-linux-thunderstorm-collector -s http://thunderstorm.test:8080 -l collector.log --upload-synchronous
```

### Tested On

Successfully tested on:

- Debian 10
- Windows 10
