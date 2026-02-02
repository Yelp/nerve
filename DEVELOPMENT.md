# Development Guide

## Quick Start

```bash
git clone https://github.com/Yelp/nerve
cd nerve
make setup
make test
```

## Development Tasks

All tasks are available via `make`:

```bash
make help          # Show all available targets
make setup         # Set up dev environment (auto-detects Docker vs local)
make setup-docker  # Build Docker development image
make setup-local   # Install dependencies locally
make test          # Run test suite
make test-docker   # Run tests in Docker container
make lint          # Check code style with StandardRB
make fix           # Auto-fix code style issues
make console       # Start interactive Ruby console
make clean         # Remove generated files
```

## Running Tests

```bash
# Run full test suite
make test

# Run specific file
bundle exec rspec spec/lib/nerve_spec.rb

# Run specific example
bundle exec rspec spec/lib/nerve_spec.rb:42
```

## Code Style

We use [StandardRB](https://github.com/standardrb/standard) for code formatting (zero-config Ruby linter).

```bash
make lint  # Check style
make fix   # Auto-fix violations
```

### Pre-commit Hooks

Install pre-commit hooks to auto-format code on commit:

```bash
pre-commit install
```

See `.pre-commit-config.yaml` for the list of hooks.

## Running Nerve Locally

```bash
# Show help
bundle exec bin/nerve --help

# Validate config
bundle exec bin/nerve -c example/nerve.conf.json --check

# Run with config (requires ZooKeeper)
bundle exec bin/nerve -c example/nerve.conf.json
```

## Project Structure

```
nerve/
├── bin/nerve              # CLI entrypoint
├── lib/
│   ├── nerve.rb           # Main application
│   ├── nerve/
│   │   ├── configuration_manager.rb  # Config parsing
│   │   ├── reporter/      # ZooKeeper/etcd reporters
│   │   ├── service_watcher/  # Health check implementations
│   │   └── ...
├── spec/                  # RSpec tests
├── example/               # Example configurations
├── Dockerfile.dev         # Development Docker image
└── Makefile               # Development tasks
```

## Contributing

1. Fork the repository
2. Create a feature branch: `git checkout -b my-feature`
3. Make changes and add tests
4. Run `make test` and `make lint`
5. Commit with descriptive message
6. Push and open a Pull Request
