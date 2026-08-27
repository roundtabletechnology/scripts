# Generate an SSH key pair and copy the public key to a remote host for passwordless authentication.
ssh-keygen -t ed25519 -C "user@host" # Generate a new SSH key
ssh-copy-id user@host # Copy the public key to the remote host
