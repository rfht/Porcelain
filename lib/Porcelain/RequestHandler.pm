package Porcelain::RequestHandler;

use strict;
use warnings;

require Exporter;
our @ISA = qw(Exporter);
our @EXPORT = qw(init_request request);

use File::LibMagic;
use Porcelain::CursesUI;	# for displaying status updates and prompts

my @supported_protocols = ("gemini", "file", "about");

# about pages
my @bookmarks;
my @config;
my @help;
my @history;
my @pod;
my @stdin;
my @subscriptions;

my %habout = (			# hash of all about addresses
	"bookmarks"	=> \@bookmarks,
	"config"	=> \@config,
	"help"		=> \@help,
	"history"	=> \@history,
	"man"		=> \@pod,
	"pod"		=> \@pod,
	"stdin"		=> \@stdin,
	"subscriptions"	=> \@subscriptions,
);

sub conn_parse {	# parse connection. args: address --> return: connection type, address (without protocol) or content array
	# Allowed patterns:
	# "^gemini://", "^file:/", "^about:", "^-$"
	# Others will need to processed separately
	# Note that addresses _without_ protocol are not allowed.
	my ($addr) = @_;
	my ($ct, $ad);		# connection, address
	my ($prot, $target);	# protocol, target
	if ($addr eq "-") {
		($prot, $target) = ("about", "stdin");
	} elsif ($addr =~ m{:}) {
		my @splitaddr = split ":", $addr;
		$prot = shift @splitaddr;
		$target = join ":", @splitaddr;
	}

	# check if the protocol is supported
	my %supp = map { $_ => 1 } @supported_protocols;	# turn array into hash; to check if element is contained in it
	if (exists($supp{$prot})) {
		if (($prot eq "gemini" || $prot eq "file") && substr($target, 0, 2) eq "//") {	# remove leading "//" from gemini address
			$target = substr $target, 2;
		}
		return ($prot, $target);
	} else {
		# not supported. Return "unsupported" and the full address
		return ("unsupported", $addr);
	}
}

sub init_request {
	@pod = @{$_[0]};
	@bookmarks = @{$_[1]};
	@history = @{$_[2]};
	@subscriptions = @{$_[3]};
}

sub request {	# first line to process all requests for an address. params: address --> return: new address
		# the new address that is returned will be fed into request again; return undef to exit
	my $rq_addr = $_[0];
	@stdin = @{$_[1]};
	my @content;

	### Determine connection type and obtain content ###
	my ($conn, $addr) = conn_parse $rq_addr;
	if ($conn eq "about") {	# about:..., stdin
		# set content
		@content = @{$habout{$addr}};
	} elsif ($conn eq "file") {	# local file
		# check MIME type
		my $magic = File::LibMagic->new;
		my $info = $magic->info_from_filename($addr);
		my $mime = $info->{mime_type};
		clean_exit $mime;
		# open file
	} elsif ($conn eq "gemini") {
		# TLS connection (check if TLS 1.3 needs to be enforced)
		# TOFU
		# opt. client cert
		# Process response header
		# if SUCCESS (2x), check MIME type, set content if compatible
	} elsif ($conn eq "unsupported") {
		# check if handler registered; if so, invoke handler
	} else {
		die "unable to process connection type: $conn";	# should not be reachable
	}
	clean_exit "conn: $conn, content length: " . scalar(@content) . "\n" . $content[0];

	### Render Content ###

	### Navigation ###
}

1;
