package Porcelain::RequestHandler;

use strict;
use warnings;

require Exporter;
our @ISA = qw(Exporter);
our @EXPORT = qw(init_request request);

use File::LibMagic;
use Porcelain::Crypto;
use Porcelain::CursesUI;	# for displaying status updates and prompts

my @supported_protocols = ("gemini", "file", "about");
my $host_cert;

# about pages
my @bookmarks;
my @config;
my @help;
my @history;
my @pod;
my @stdin;
my @subscriptions;

my @error	= ("Error completing the request");	# TODO: flesh out; format; list error details
my @new		= ("New page");				# TODO: flesh out, e.g. Porcelain in ASCII art

my %habout = (			# hash of all about addresses
	"bookmarks"	=> \@bookmarks,
	"config"	=> \@config,
	"error"		=> \@error,
	"help"		=> \@help,
	"history"	=> \@history,
	"man"		=> \@pod,
	"new"		=> \@new,
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

sub parse_mime_ext {	# determine how to parse/format based on MIME type and optionally filename extension
			# params: MIME type, filename (optional) --> return: string "gemini", "plain", or "unsupported"
	my ($mime, $filenam) = @_;
	if ($mime eq "text/gemini" || $filenam =~ /\.gemini$/ || $filenam =~ /\.gmi$/) {
		return "gemini";
	} elsif ($mime eq "text/plain") {
		return "plain";
	} else {
		return "unsupported";
	}
}

sub fileext {	# simple sub to return the file extension. params: filename --> return: extension (e.g. '.ogg')
	return "." . $_[0] =~ s/.*\.//r;
}

sub addr2dom {	# get the domain of an address. address needs to be _without_ leading 'gemini://'!
		# params: address --> return: (domain, port)
	my $domport =  $_[0] =~ s|/.*||r;
	my ($domain, $port) = split ":", $domport;
	return ($domain, $port);
}

sub request {	# first line to process all requests for an address. params: address --> return: new address
		# the new address that is returned will be fed into request again; return undef to exit
	my $rq_addr = $_[0];
	@stdin = @{$_[1]};
	my @content;
	my $render_format = undef;	# can be "gemini" or "plain"

	### Determine connection type and obtain content ###
	my ($conn, $addr) = conn_parse $rq_addr;
	if ($conn eq "about") {	# about:..., stdin
		# set content
		@content = @{$habout{$addr}};
	} elsif ($conn eq "file") {	# local file
		# check MIME type
		if (not -f $addr) {
			return "about:error";
		}
		my $magic = File::LibMagic->new;
		my $mime = $magic->info_from_filename($addr)->{mime_type};
		$render_format = parse_mime_ext $mime, $addr;
		# get content from file
		# TODO: allow custom openers for text/gemini or text/plain?
		if ($render_format ne "unsupported") {
			@content = Porcelain::Porcelain::readtext $addr;
		} else {
			if (defined $Porcelain::Main::open_with{$mime}) {		# TODO: use a local sub instead of Porcelain::Main::open_with
				system("$Porcelain::Main::open_with{$mime} $addr");	# TODO: make nonblocking; may need "use threads" https://perldoc.perl.org/threads
				return "about:new";
			} elsif (defined $Porcelain::Main::open_with{fileext($addr)}) {
				system("$Porcelain::Main::open_with{fileext($addr)} $addr");
				return "about:new";
			} else {
				# failed to open; set error page
				return "about:error";
			}
		}
	} elsif ($conn eq "gemini") {

		# TLS connection (TODO: check if TLS 1.3 needs to be enforced)
		# TODO: check if client cert is associated; if so, set $client_cert and $client_key
		my ($domain, $port) = addr2dom $addr;
		$port = 1965 unless $port;
		my ($client_cert, $client_key);
		undef $host_cert;
		# TODO: check that sslcat_porcelain works with port in $addr
		(my $response, my $err, $host_cert) = sslcat_porcelain($domain, $port, "$addr\r\n", $client_cert, $client_key);
		die "Error while trying to establish TLS connection: $!" if $err;	# TODO: die => clean_die;

		# TOFU
		die "No certificate received from host" if (not defined $host_cert);	# TODO: die => clean_die;
		# TODO: 3 scenarios:
		#	(2, Date): Server verified (last on date)
		#	(1, Date): TOFU ok (stored on date)
		#	(0, Error string): Error, details in string. (fingerprint mismatch, expired, unsupported fingerprint algorithm...
		if (my $r = validate_cert($host_cert, $domain)) {
			my $r1;
			do {
				$r1 = c_err "Cert validation error: $r. [C]ontinue or [A]bort?";
			} until ($r1 =~ /^[CcAa]$/);
			clean_exit if (lc($r1) eq "a");
		}
		clean_exit Net::SSLeay::X509_get_fingerprint($host_cert, "sha256");
		# Process response header
		# if SUCCESS (2x), check MIME type, set content if compatible
	} elsif ($conn eq "unsupported") {
		# check if handler registered; if so, invoke handler
		my $protocol = (split ":", $addr)[0];
		if (defined $Porcelain::Main::open_with{$protocol}) {
			system("$Porcelain::Main::open_with{$protocol} $addr");
			return "about:new";
		} else {
			return "about:error";
		}
	} else {
		die "unable to process connection type: $conn";	# should not be reachable
	}
	clean_exit "conn: $conn, addr: $addr, content length: " . scalar(@content) . "\n" . $content[0];

	### Render Content ###

	### Navigation ###
}

1;
