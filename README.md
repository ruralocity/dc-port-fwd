# Devcontainer port forwarder

I like devcontainers, but I don't always like Visual Studio Code. `devcontainers-cli` is ok, but doesn't support port forwarding for some odd reason. So here's a script to help. It uses `socat` inside the container to establish the connection. Based on [harrismcc/devcontainer-port-forward](https://github.com/harrismcc/devcontainer-port-forward) but ported to Ruby so I could understand it better for my needs.

This is only sort of tested with a Rails app and a Django app.

## Alleged features

- Forward multiple ports simultaneously
- Efficient data transfer with optimized buffer sizes
- Automatic verification of container existence
- Checks for socat installation in the container

## Known issues

- If you're using a Ruby version manager, the script may try to reinstall dependencies for each Ruby version. But you can run it directly in this directory to avoid that, I think.
- I did most of this pair-coding with Aider and have spot-checked but not thoroughly reviewed.
- Yeah, we should probably write this in Rust or something.

## Requirements

- Ruby 3.something; I'm using 3.3 at the moment
- `devcontainers-cli` installed on the host machine
- A devcontainer up and running: `devcontainer up --workspace-folder .`
- `socat` installed in the running devcontainer (or you'll be prompted to install it)

## Usage

```shell
./forward.rb -p PORT[,PORT2,...] -c CONTAINER_ID
```

## Options

```
-p, --ports PORTS        Specify ports to forward (comma-separated)
                          Each port will be forwarded to the same port in the container
-c, --container ID       Specify the Docker container ID or name
```

## Example

```
# Forward local port 8080 to port 8080 in container abc123
./forward.rb -p 8080 -c abc123

# Forward multiple ports (3000, 8080, and 9000) to the same ports in container web_app
./forward.rb -p 3000,8080,9000 -c web_app

# If socat is not installed in the container, you'll be prompted to install it:
devcontainer exec --workspace-folder . -- sudo apt-get update && docker exec abc123 apt-get install -y socat
```
