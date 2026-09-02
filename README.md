# gunti

A terminal file manager in Odin. there are no ncurses and no dependencies. Just `core:os`
and ANSI escapes.

Built in stages. Right now it is at stage 1: it lists a directory
and exits. It does not navigate, it does not take input and so on. Does nothing, yet.  

The mostt apt description for gunti now is that its a slightly worse 'ls'

## build

    odin build . -out:gunti

## usage

    ./gunti

Prints the sorted contents of the current directory, one per line, directories
suffixed with `/`. That's it. That's the whole program.

## requirements

Odin `dev-2026-08` or newer.

## Some obvious things that aren't here yet(differed to later stages)

1. A config file
2. themes 
3. keybinding system 
4. preview panes
