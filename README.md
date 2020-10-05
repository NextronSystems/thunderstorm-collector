![Thunderstorm Collector](images/thunderstorm-collector-logo.png)

# THOR Thunderstorm Collector

The Thunderstorm collectors allow for easy uploads of files to a THOR Thunderstorm instance.
Information on THOR Thunderstorm can be found [here](https://www.nextron-systems.com/2020/09/25/theres-a-thunderstorm-coming/).

The different collectors allow users to select files based on size, age or type.

This repository contains two types of collectors:

- [Scripts](scripts/) written in different script languages, available for Linux, Unix and Microsoft Windows
- A [Thunderstorm Collector](go/) written in Go that can be compiled and is pre-compiled for numerous target platforms

Visit the links to the respective sub directories for a detailed README on the different collectors.

## Which Collector Should I Use?

We recommend using the Thunderstorm Collector written in Go. Use the scripts in cases in which running a compiled binary is out of question. This could be the case in some very sensitive environmnts or on platforms that are unsupported (e.g. IOT devices with proprietary OS).

## Write Your Own Collector

If you'd like to write your own collector, you can find a Python module named `thunderstormAPI` in [this](https://github.com/NextronSystems/thunderstormAPI) repository.
