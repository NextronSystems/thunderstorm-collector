![Thunderstorm Collector](images/thunderstorm-collector-logo.png)

# THOR Thunderstorm Collector

THOR Thunderstorm collectors facilitate effortless file uploads to a THOR Thunderstorm instance. More details on THOR Thunderstorm are available [here](https://www.nextron-systems.com/2020/10/01/theres-a-thunderstorm-coming/).

Users can filter files based on their size, age, extension or type.

This repository features:

- [Scripts](scripts/) in diverse scripting languages for Linux, Unix, and Microsoft Windows.
- [Thunderstorm Collector](go/) developed in Go, pre-compiled for multiple platforms.

For a comprehensive guide on each collector, refer to the linked subdirectories.

## Which Collector Should You Choose?

The Thunderstorm Collector in Go is our top recommendation. Opt for the scripts only when running a compiled binary isn't feasible, as in highly-sensitive settings or on unsupported platforms like proprietary OS IOT devices.

## Craft Your Own Collector

Interested in creating a unique collector? A Python module, `thunderstormAPI`, is available in [this](https://github.com/NextronSystems/thunderstormAPI) repository for your use.
