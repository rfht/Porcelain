#!/usr/bin/env perl

# Copyright (c) 2021 Thomas Frohwein
#
# Permission to use, copy, modify, and distribute this software for any
# purpose with or without fee is hereby granted, provided that the above
# copyright notice and this permission notice appear in all copies.
#
# THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
# WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
# MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
# ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
# WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
# ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
# OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

use strict;
use warnings;
package Porcelain::Main;

use IO::Pager::Perl;
use Net::SSLeay qw(sslcat);				# p5-Net-SSLeay
use OpenBSD::Pledge;					# OpenBSD::Pledge(3p)
use OpenBSD::Unveil;					# OpenBSD::Unveil(3p)
use Term::ReadKey;					# for use with IO::Pager::Perl

# stdio promise is always implied by OpenBSD::Pledge
# needed promises for sslcat: rpath inet dns
# needed promises for IO::Pager::Perl: tty
pledge(qw ( rpath inet dns tty unveil ) ) || die "Unable to pledge: $!";
#pledge() || die "Unable to pledge: $!";

# needed paths for sslcat: /etc/resolv.conf (r)
# needed paths for IO::Pager::Perl: /etc/termcap (r)
#unveil( "$ENV{'HOME'}/Downloads", "rw") || die "Unable to unveil: $!";
unveil( "/usr/local/libdata/perl5/site_perl/amd64-openbsd/auto/Net/SSLeay", "r") || die "Unable to unveil: $!";
unveil( "/etc/resolv.conf", "r") || die "Unable to unveil: $!";
unveil( "/etc/termcap", "r") || die "Unable to unveil: $!";
unveil() || die "Unable to lock unveil: $!";

my $t = IO::Pager::Perl->new();
my $reply;
my $err;
my $server_cert;
($reply, $err, $server_cert) = sslcat("gemini.circumlunar.space", 1965, "gemini://gemini.circumlunar.space/docs/specification.gmi");
#print $reply;
$t->add_text( $reply );
$t->more();
