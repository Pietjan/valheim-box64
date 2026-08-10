image_name = valheim-box64
image_tag = latest
image_ref = localhost/${image_name}:${image_tag}
box64_ref = v0.4.5-1
engine = podman
quadlet_dir = ${HOME}/.config/containers/systemd
env_dir = ${HOME}/.config/valheim

# ==================================================================================== #
# HELPERS
# ==================================================================================== #

## help: print this help message
.PHONY: help
help:
	@echo 'Usage:'
	@sed -n 's/^##//p' ${MAKEFILE_LIST} | column -t -s ':' | sed -e 's/^/ /'

.PHONY: confirm
confirm:
	@echo -n 'Are you sure? [y/N] ' && read ans && [ $${ans:-N} = y ]

## preflight: check the host can build and run this image
.PHONY: preflight
preflight:
	@echo '--- page size (must be 4096; box64 does not support 64k pages)'
	@getconf PAGESIZE
	@echo '--- host architecture'
	@uname -m
	@echo '--- free disk (the build needs ~6G)'
	@df -h / | tail -1
	@echo '--- udp 2456-2457 in firewalld'
	@firewall-cmd --list-ports 2>/dev/null || echo 'firewalld not running or not permitted'

# ==================================================================================== #
# QUALITY CONTROL
# ==================================================================================== #

## audit: run all static checks
.PHONY: audit
audit: lint/shell lint/container

## lint/shell: shellcheck the entrypoint
.PHONY: lint/shell
lint/shell:
	shellcheck entrypoint.sh

## lint/container: lint the Dockerfile and validate the quadlet units
.PHONY: lint/container
lint/container:
	${engine} run --rm -i docker.io/hadolint/hadolint < Dockerfile
	/usr/libexec/podman/quadlet -dryrun -user

# ==================================================================================== #
# DEVELOPMENT
# ==================================================================================== #

## build/image: build the arm64 server image
.PHONY: build/image
build/image:
	${engine} build \
		--build-arg BOX64_REF=${box64_ref} \
		--tag ${image_ref} \
		.

## image/verify: prove box64 can load the x86_64 server binary
.PHONY: image/verify
image/verify:
	${engine} run --rm --entrypoint box64 ${image_ref} -v
	${engine} run --rm --entrypoint box64 ${image_ref} /srv/valheim/valheim_server.x86_64 -help

## run/local: run the server in the foreground with a throwaway world
.PHONY: run/local
run/local:
	${engine} run --rm -it \
		--name valheim-local \
		--publish 2456:2456/udp \
		--publish 2457:2457/udp \
		--env VALHEIM_NAME='Local Test' \
		--env VALHEIM_WORLD='LocalTest' \
		--env VALHEIM_PASSWORD='localtest' \
		--env VALHEIM_PUBLIC=0 \
		${image_ref}

## run/shell: open a shell in the image
.PHONY: run/shell
run/shell:
	${engine} run --rm -it --entrypoint /bin/bash ${image_ref}

# ==================================================================================== #
# OPERATIONS
# ==================================================================================== #

## quadlet/install: install the rootless quadlet units and env file
.PHONY: quadlet/install
quadlet/install:
	mkdir -p ${quadlet_dir} ${env_dir}
	install -m 0644 quadlet/valheim.container quadlet/valheim-saves.volume ${quadlet_dir}/
	test -f ${env_dir}/valheim.env || install -m 0600 quadlet/valheim.env.example ${env_dir}/valheim.env
	systemctl --user daemon-reload
	@echo
	@echo 'Edit ${env_dir}/valheim.env, then: make quadlet/start'

## quadlet/start: enable and start the server unit
.PHONY: quadlet/start
quadlet/start:
	loginctl enable-linger $${USER}
	systemctl --user start valheim

## quadlet/stop: stop the server unit
.PHONY: quadlet/stop
quadlet/stop:
	systemctl --user stop valheim

## quadlet/logs: follow the server log
.PHONY: quadlet/logs
quadlet/logs:
	journalctl --user -u valheim -f

## quadlet/status: show unit status and the listening UDP sockets
.PHONY: quadlet/status
quadlet/status:
	systemctl --user status valheim --no-pager || true
	ss -ulpn | grep -E '2456|2457' || echo 'no listener on 2456/2457'

## quadlet/uninstall: remove the quadlet units (keeps the save volume)
.PHONY: quadlet/uninstall
quadlet/uninstall: confirm
	systemctl --user stop valheim || true
	rm -f ${quadlet_dir}/valheim.container ${quadlet_dir}/valheim-saves.volume
	systemctl --user daemon-reload

## saves/backup: tar the save volume to ./valheim-saves-<date>.tar.gz
.PHONY: saves/backup
saves/backup:
	${engine} run --rm \
		--volume valheim-saves:/saves:ro,Z \
		--volume $${PWD}:/backup:Z \
		docker.io/library/debian:trixie-slim \
		tar czf /backup/valheim-saves-$$(date +%Y%m%d-%H%M%S).tar.gz -C /saves .
