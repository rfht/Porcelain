package Porcelain::RequestHandler;

use strict;
use warnings;

require Exporter;
our @ISA = qw(Exporter);
our @EXPORT = qw(request);

use Porcelain::CursesUI;	# for displaying status updates and prompts

sub request {	# first line to process all requests for an address. params: address --> return: new address
		# the new address that is returned will be fed into request again; return undef to exit
	my $addr = $_[0];

	### Determine connection type and obtain content ###
	my $ct = conn_type $addr;
	if ($ct eq 'gemini') {
		# TLS connection (check if TLS 1.3 needs to be enforced)
		# TOFU
		# opt. client cert
		# Process response header
		# if SUCCESS (2x), check MIME type, set content if compatible
	} elsif ($ct eq 'internal') {	# about:... or STDIN
		# set content
	} elsif ($ct eq 'local') {
		# open file
		# check MIME type
	} elsif ($ct eq 'other') {
		# check if handler registered; if so, invoke handler
	} else {
		die "unable to process connection type: $ct";
	}

	### Render Content ###

	### Navigation ###
}

sub conn_type {	# args: address --> return: connection type
	# TODO: how to reliably differentiate between gemini location omitting 'gemini://' and local file
	# gemini connection
	"^gemini://", "^file:///", "^about:"

}

1;