package Porcelain::RequestHandler;

use strict;
use warnings;

require Exporter;
our @ISA = qw(Exporter);
our @EXPORT = qw(init_request request);

use Any::URI::Escape;		# to handle percent encoding (uri_escape())
use Encode qw(encode decode);
use File::LibMagic;
use Porcelain::Crypto;
use Porcelain::CursesUI;	# for displaying status updates and prompts
use Porcelain::Porcelain;

my @supported_protocols = ("gemini", "file", "about");
my $host_cert;
my $redirect_count = 0;
my $max_redirect = 5;	# TODO: allow custom value in config

# about pages
my @bookmarks;
my %client_certs;
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
	%client_certs = map {split /\s+/} @{$_[4]};
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

sub find_client_key {	# find best match for client_key. params: address --> return: 
	my ($addr) = @_;
	my $ret = undef;
	foreach (keys %client_certs) {
		$ret = $_ if length($_) > length($ret) && $_ eq substr($addr, 0, length($_));
	}
	return $ret;
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
			@content = readtext $addr;
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
		my ($domain, $port) = addr2dom $addr;
		$port = 1965 unless $port;
		my ($client_cert, $client_key) = (undef, undef);
		if (my $client_key_addr = find_client_key $addr) {
			($client_cert, $client_key) = $client_certs{find_client_key $addr};
		}
		undef $host_cert;		# TODO: really needed? Can this line be removed somehow?
		(my $response, my $err, $host_cert) = sslcat_porcelain($domain, $port, "gemini://$addr\r\n", $client_cert, $client_key);
		die "Error while trying to establish TLS connection: $!" if $err;	# TODO: die => clean_die;

		# TOFU
		die "No certificate received from host" if (not defined $host_cert);	# TODO: die => clean_die;
		my ($r, $details) = validate_cert($host_cert, $domain, \@Porcelain::Main::known_hosts);
		if ($r == 3) {
			# (3, Date): Server verified, date is LAST date of verification (more recent is better)
		} elsif ($r == 2) {
			# (2, Date): TOFU ok, date is the ORIGINAL date that TOFU was stored (more distant is better)
		} elsif ($r == 1) {
			# (1, fingerprint): unknown host, fingerprint for storing
		} elsif ($r == 0) {
			# (0, fingerprint): fingerprint mismatch, new fingerprint offered in case user wants to update it
			c_err "fingerprint mismatch. [U]pdate fingerprint, [A]bort? ";
		} elsif ($r == -1) {
			# (-1, string): unexpected error, see details in string
			return "about:error";	# TODO: add details to the error
		} else {
			die "invalid response from sub validate_cert: $r, $details";	# should not be reached
		}

		# Process response header
		@content = lines(decode('UTF-8', $response));	# TODO: support non-UTF8 encodings?
		my ($status, $meta) = sep(shift @content);
		my $shortstatus = substr $status, 0, 1;
		$redirect_count = 0 if $shortstatus != 3;
		if ($shortstatus == 1) {
			my $input = uri_escape(c_prompt_str $meta . ": ");	# TODO: check that meta doesn't end in ':'?
			return $addr . "?" . $input if $input;
			return $addr;
			# 10: input
			# 11: sensitive input
		} elsif ($shortstatus == 2) {
			# 20: success
			my ($mime) = $meta =~ /^([[:alpha:]\/]+)/;
			$render_format = parse_mime_ext($mime, $addr);	# TODO: deal with language etc in $meta
			# TODO: allow custom openers for text/gemini or text/plain?
			if ($render_format eq "unsupported") {
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
		} elsif ($shortstatus == 3) {
			die "ERROR: too many redirects" if ++$redirect_count > $max_redirect;
			# TODO: add config option to require confirmation for all redirects
			my $redir_addr = url2absolute("gemini://" . $addr, $meta);
			die "ERROR: cross-protocol redirects not allowed" if not $redir_addr =~ m{^gemini://};
			return $redir_addr;
			# 30: temporary redirect
			# 31: permanent redirect
		} elsif ($shortstatus == 4) {
			return "about:error";
			# 40: temporary failure
			# 41: server unavailable
			# 42: CGI error
			# 43: proxy error
			# 44: slow down
		} elsif ($shortstatus == 5) {
			return "about:error";
			# 50: permanent failure
			# 51: not found
			# 52: gone
			# 53: proxy request refused
			# 59: bad request
		} elsif ($shortstatus == 6) {
			# TODO: add option to go back in history
			do {
				$r = c_prompt_ch "Client certificate requested, but no valid one found. Create new cert for $addr? [Yn]";
			} until $r =~ /^[YyNn]*$/;
			chomp $r;
			if (length($r) == 0 || lc($r) eq "y") {
				do {
					$r = c_prompt_ch "Enter certificate lifetime in days: ";
				} until $r =~ /^\d+$/;
				my $sha = gen_identity $r;
				$client_certs{$addr} = $sha;
			}
			return $addr;
			# 60: client certificate required
			# 61: client certificate not authorised
			# 62: certificate not valid
		} else {
			die "Invalid status code in response: $status; meta: $meta";
		}

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
