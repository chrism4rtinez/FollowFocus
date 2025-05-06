SKYLIGHT_AVAILABLE := $(shell test -d /System/Library/PrivateFrameworks/SkyLight.framework && echo 1 || echo 0)
override CXXFLAGS += -O2 -Wall -fobjc-arc -D"NS_FORMAT_ARGUMENT(A)=" -D"SKYLIGHT_AVAILABLE=$(SKYLIGHT_AVAILABLE)" -DEXPERIMENTAL_FOCUS_FIRST

.PHONY: all clean install

all: FollowFocus FollowFocus.app

clean:
	rm -f FollowFocus
	rm -rf FollowFocus.app

install: FollowFocus.app
	rm -rf /Applications/FollowFocus.app
	cp -r FollowFocus.app /Applications/

FollowFocus: FollowFocus.mm
        ifeq ($(SKYLIGHT_AVAILABLE), 1)
	    g++ $(CXXFLAGS) -o $@ $^ -framework AppKit -F /System/Library/PrivateFrameworks -framework SkyLight
        else
	    g++ $(CXXFLAGS) -o $@ $^ -framework AppKit
        endif

FollowFocus.app: FollowFocus Info.plist FollowFocus.icns
	chmod +x ./create-app-bundle.sh
	./create-app-bundle.sh