[![Build Status](https://travis-ci.org/airbnb/nerve.png?branch=master)](https://travis-ci.org/airbnb/nerve)

# Nerve

Nerve is a utility for tracking the status of machines and services.
It runs locally on the boxes which make up a distributed system, and reports state information to a distributed key-value store.
At Airbnb, we use Zookeeper as our key-value store.
The combination of Nerve and [Synapse](https://github.com/airbnb/synapse) make service discovery in the cloud easy!

## Motivation ##

We already use [Synapse](https://github.com/airbnb/synapse) to discover remote services.
However, those services needed boilerplate code to register themselves in [Zookeeper](http://zookeeper.apache.org/).
Nerve simplifies underlying services, enables code reuse, and allows us to create a more composable system.
It does so by factoring out the boilerplate into it's own application, which independenly handles monitoring and reporting.

Beyond those benefits, nerve also acts as a general watchdog on systems.
The information it reports can be used to take action from a centralized automation center: action like scaling distributed systems up or down or alerting ops or engineering about downtime.

## Installation ##

To download and run the nerve binary, first install a version of ruby. Then,
install nerve with:

```bash
$ mkdir -p /opt/smartstack/nerve

# If you want to install specific versions of dependencies such as an older
# version of the aws-sdk, the docker-api, etc, gem install that here *before*
# gem installing nerve. This is also where you would gem install
# custom reporters.

# If you are on Ruby 2.X use --no-document instead of --no-ri --no-rdoc
$ gem install nerve --install-dir /opt/smartstack/nerve --no-ri --no-rdoc
```

This will download nerve and its dependencies into /opt/smartstack/nerve. You
might wish to omit the `--install-dir` flag to use your system's default gem
path, however this will require you to run `gem install nerve` with root
permissions. You can also install via bundler, but keep in mind you'll pick up
Nerve's version of library dependencies and possibly not the ones you need
for your infra/apps.

## Configuration ##

Nerve builds its effective configuration from three sources:

* Base config file (`--config`)
* Optional overlay config (`--config-overlay`, deep-merged)
* Optional CLI overrides (applied last)

Start with `example/nerve.conf.json` for a working baseline.

For the full reference, including merge semantics, precedence, CLI flag scope,
and service/check/reporter fields, see:

* [`docs/configuration.md`](docs/configuration.md)
* [`docs/config-schema.json`](docs/config-schema.json)

## Contributing

1. Fork it
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create new Pull Request
