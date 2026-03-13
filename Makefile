PREFIX ?= /usr

.PHONY: install lint test preflight clean package package-host package-trixie

install:
	install -d $(DESTDIR)$(PREFIX)/lib/raid-drive-validator/bin
	install -d $(DESTDIR)$(PREFIX)/lib/raid-drive-validator/lib
	install -d $(DESTDIR)$(PREFIX)/lib/raid-drive-validator/dashboard
	install -d $(DESTDIR)$(PREFIX)/share/doc/raid-drive-validator/examples
	install -m 0755 bin/drive_burnin_test.sh $(DESTDIR)$(PREFIX)/lib/raid-drive-validator/bin/
	install -m 0755 bin/drive_burnin_tmux.sh $(DESTDIR)$(PREFIX)/lib/raid-drive-validator/bin/
	install -m 0755 lib/common.sh $(DESTDIR)$(PREFIX)/lib/raid-drive-validator/lib/
	install -m 0755 lib/disk_discovery.sh $(DESTDIR)$(PREFIX)/lib/raid-drive-validator/lib/
	install -m 0755 lib/scoring.sh $(DESTDIR)$(PREFIX)/lib/raid-drive-validator/lib/
	install -m 0755 dashboard/dashboard.sh $(DESTDIR)$(PREFIX)/lib/raid-drive-validator/dashboard/
	install -d $(DESTDIR)$(PREFIX)/lib/raid-drive-validator/tools
	install -m 0755 tools/generate_drive_markdown_report.sh $(DESTDIR)$(PREFIX)/lib/raid-drive-validator/tools/
	install -m 0755 tools/generate_batch_markdown_summary.sh $(DESTDIR)$(PREFIX)/lib/raid-drive-validator/tools/
	install -m 0755 tools/wait_and_generate_batch_summary.sh $(DESTDIR)$(PREFIX)/lib/raid-drive-validator/tools/
	install -m 0644 README.md $(DESTDIR)$(PREFIX)/share/doc/raid-drive-validator/
	install -m 0644 examples/example-run.sh $(DESTDIR)$(PREFIX)/share/doc/raid-drive-validator/examples/

lint:
	shellcheck -x bin/*.sh lib/*.sh dashboard/*.sh tools/*.sh tests/*.sh

test:
	bash tests/test_discovery.sh
	bash tests/test_scoring.sh
	bash tests/test_preflight.sh
	bash tests/test_reports.sh
	bash tests/test_dashboard.sh

preflight:
	bash tools/host_preflight.sh

clean:
	rm -rf drive_test_reports
	rm -f ../raid-drive-validator_*.deb ../raid-drive-validator_*.buildinfo ../raid-drive-validator_*.changes

package-host:
	dpkg-buildpackage -us -uc -b

package-trixie:
	sudo tools/build_trixie_package.sh /srv/chroot/trixie-amd64

package: package-host
