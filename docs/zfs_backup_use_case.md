# ZFS backup use case

The original deployment goal was to qualify 4 TB HDDs for an 8-disk RAIDZ2 backup pool on the host `stein`, keep a 9th as hot spare, and then replicate from the operational ZFS host `newton` over 10 GbE using native ZFS send/receive.
