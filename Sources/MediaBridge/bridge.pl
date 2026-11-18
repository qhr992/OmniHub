#!/usr/bin/perl
# Loads MediaBridge.dylib into this (Apple-signed) perl process and hands
# control to it. See MediaBridge.m for why perl is involved at all.
use strict;
use warnings;
use DynaLoader;

my $lib = shift @ARGV or die "usage: bridge.pl <MediaBridge.dylib>\n";
my $handle = DynaLoader::dl_load_file($lib, 0)
    or die "cannot load $lib: " . DynaLoader::dl_error() . "\n";
my $symbol = DynaLoader::dl_find_symbol($handle, "omnihub_media_stream")
    or die "symbol not found\n";
DynaLoader::dl_install_xsub("main::omnihub_media_stream", $symbol);
$| = 1;
main::omnihub_media_stream();
