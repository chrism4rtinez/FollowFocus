#!/bin/bash
set -e  # Exit immediately if a command exits with a non-zero status

# Remove any existing application bundle
if [ -d "FollowFocus.app" ]; then
    rm -rf FollowFocus.app
    echo "Removed existing FollowFocus.app"
fi

# Create the necessary directory structure
mkdir -p FollowFocus.app/Contents/MacOS
mkdir -p FollowFocus.app/Contents/Resources

# Copy the executable
if [ ! -f "FollowFocus" ]; then
    echo "Error: FollowFocus executable not found"
    exit 1
fi
cp FollowFocus FollowFocus.app/Contents/MacOS

# Copy the Info.plist
if [ ! -f "Info.plist" ]; then
    echo "Error: Info.plist not found"
    exit 1
fi
cp Info.plist FollowFocus.app/Contents

# Copy the icon
if [ ! -f "FollowFocus.icns" ]; then
    echo "Warning: FollowFocus.icns not found, application will use default icon"
else
    cp FollowFocus.icns FollowFocus.app/Contents/Resources
fi

# Set proper permissions
chmod 755 FollowFocus.app
chmod 755 FollowFocus.app/Contents/MacOS/FollowFocus

echo "Successfully created FollowFocus.app"