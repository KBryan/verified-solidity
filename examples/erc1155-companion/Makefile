REACH = ../../reach

.PHONY: run
run:
	REACH_DOCKER=0 $(REACH) sol index.rsh --companion-check off
	./foundry-test/run.sh
