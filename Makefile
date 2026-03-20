PREFIX ?= /usr

.PHONY: install lint test preflight clean distclean build package package-host

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
	install -m 0755 tools/host_preflight.sh $(DESTDIR)$(PREFIX)/lib/raid-drive-validator/tools/
	install -m 0755 tools/create_raidz2_pool.sh $(DESTDIR)$(PREFIX)/lib/raid-drive-validator/tools/
	install -m 0755 tools/stress_zpool.sh $(DESTDIR)$(PREFIX)/lib/raid-drive-validator/tools/
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
	bash tests/test_zpool_create.sh
	bash tests/test_zpool_stress.sh
	bash tests/test_fio_flag_usage.sh

preflight:
	bash tools/host_preflight.sh

clean:
	rm -rf drive_test_reports
	rm -f raid-drive-validator_*.deb raid-drive-validator_*.buildinfo raid-drive-validator_*.changes raid-drive-validator_*.build

distclean: clean
	rm -rf preflight_reports .build

build:
	tools/build_package.sh

package-host:
	dpkg-buildpackage -us -uc -b

package: build
