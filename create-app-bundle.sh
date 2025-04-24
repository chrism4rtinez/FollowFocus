#!/bin/bash

rm -rf FollowFocus.app && \
mkdir -p FollowFocus.app/Contents/MacOS && \
mkdir FollowFocus.app/Contents/Resources && \
cp FollowFocus FollowFocus.app/Contents/MacOS && \
cp Info.plist FollowFocus.app/Contents && \
cp FollowFocus.icns FollowFocus.app/Contents/Resources && \
chmod 755 FollowFocus.app && echo "Successfully created FollowFocus.app"
