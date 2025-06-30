# Speltti - fast spell checking plugin for micro-editor

Fast aspell plugin for micro-editor. 

Quick and responsive for book size documents, too. 

Free, open source software. MIT License. 

Warning: *Alpha quality, vibe coded. And only works with development version of micro (as of 2025-06-30 w27 Mon).* But it does work on my machine. 

## How so fast?

Speltti is fast and responsive. I tested it with a 3moby.md, a text document with the text of "Moby Dick" three times, and it worked nicely (and fast) on my machine. 

Speltti achieves this speed by only checking the visible part of the document (about 70 lines), instead of the whole document (47k lines). As new lines are added, this will trigger updated checks, where the size (70 vs 47k) start to matter. 

To keep the user interface responsive while working, Speltti only starts the spell check after user has been idle for half a second. 

## Annoying?

Spell check might not be useful for source code. 

You can easily toggle Speltti on and off: 

	Ctrl-E> set speltti.check off

	Ctrl-E> set speltti.check on

## Install

Compile and install [latest micro](https://github.com/zyedidia/micro). From memory:

	$ git clone https://github.com/zyedidia/micro
	$ cd micro
	$ make build
	$ ./micro --version

This only works with the latest development version of micro. This does not work with the micro that comes with Debian 12-Bookworm, nor the version that was released in 2024. The version that works for me was

	$ micro --version
	Version: 2.0.15-dev.230
	Commit hash: 41b912b5
	Compiled on June 30, 2025

Copy the folder into $HOME/.config/micro/plug/speltti/

Run micro. 

## Forked

Speltti is forked from [micro-aspell-plugin](https://github.com/priner/micro-aspell-plugin). Micro Aspell Plugin was created by @priner Ján Priner, with contributions from @RaphyJake Raphael Jacobs and @hroncok Miro Hrončok. Bugs in Speltti are mine. 

Spell checker is quite an essential plugin for a text editor. Original aspell plugin was quite helpful for short documents. However, as I write [books](https://terokarvinen.com/books/), I also need spell checking with long documents. Here, the original plugin was very slow, and also slowed down the whole editor. Thus, Speltti was born.

I did not immediately offer my code to micro-aspell-plugin as a PR, because the original looks well made, and this one is a test on vibe coding. 

Copyright 2025 Tero Karvinen https://TeroKarvinen.com

