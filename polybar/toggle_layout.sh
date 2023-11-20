#!/bin/bash

current_layout=$(setxkbmap -query | awk '/layout/{print $2}')
new_layout="de"  # Change this to the layout you want to switch to (e.g., "de" for German)

if [ "$current_layout" = "$new_layout" ]; then
    setxkbmap -layout "us"
else
    setxkbmap -layout "$new_layout"
fi