package Porcelain::Crypto;

use strict;
use warnings;

require Exporter;
our @ISA = qw(Exporter);
our @EXPORT = qw(fingerprint gen_client_cert gen_identity gen_privkey init_crypto
		store_cert store_privkey validate_cert sslcat_porcelain
		$hosts_file $idents_dir
);

use Net::SSLeay;
use POSIX qw(strftime);
use Porcelain::CursesUI;	# for c_warn
use Porcelain::Porcelain;	# for append_file

use constant DEFAULT_FP_ALGO => "sha256";
use constant DEFAULT_RSA_BITS => 2048;
use constant RSA_EXPONENT => 65537;
# TODO: allow setting/modifying $fp_algo, $rsa_bits
my $fp_algo;
my $rsa_bits;

our $idents_dir;
our $hosts_file;

my @known_hosts;

my $r;		# hold short-term return values

sub gen_privkey {	# --> return private key
	# see https://stackoverflow.com/questions/256405/programmatically-create-x509-certificate-using-openssl
	my $pkey = Net::SSLeay::EVP_PKEY_new();
	my $rsa = Net::SSLeay::RSA_generate_key($rsa_bits || DEFAULT_RSA_BITS, RSA_EXPONENT) or die;	# returns value corresponding to openssl's RSA structur; other optional args: $perl_cb, $perl_cb_arg
	Net::SSLeay::EVP_PKEY_assign_RSA($pkey, $rsa) or die;
	return $pkey;
}

sub gen_client_cert {	# days for cert validity, private key --> return cert
	# see https://stackoverflow.com/questions/256405/programmatically-create-x509-certificate-using-openssl
	my ($days_val, $pkey) = @_;
	my $x509 = Net::SSLeay::X509_new();
	die unless $x509;
	Net::SSLeay::ASN1_INTEGER_set(Net::SSLeay::X509_get_serialNumber($x509), 1) or die;
	Net::SSLeay::X509_gmtime_adj(Net::SSLeay::X509_get_notBefore($x509), 0) or die;
	Net::SSLeay::X509_gmtime_adj(Net::SSLeay::X509_get_notAfter($x509), 60 * 60 * 24 * $days_val);
	Net::SSLeay::X509_set_pubkey($x509, $pkey);
	my $sname = Net::SSLeay::X509_get_subject_name($x509);
	Net::SSLeay::X509_set_issuer_name($x509, $sname);	# subject name and issuer name are the same - self-signed cert
	Net::SSLeay::X509_sign($x509, $pkey, Net::SSLeay::EVP_sha1());	# TODO: is SHA-1 a reasonable algorithm here?
	return $x509;
}

# TODO: merge store_privkey and store_cert into same function (very similar)
sub store_privkey {	# privkey, filename -->
	my ($pk, $filenam) = @_;
	open my $fh, '>:raw', $filenam or die;
	print $fh Net::SSLeay::PEM_get_string_PrivateKey($pk);
	close $fh;
}

sub store_cert {	# x509 cert, filename -->
	my ($x509, $filenam) = @_;
	open my $fh, '>:raw', $filenam or die;
	print $fh Net::SSLeay::PEM_get_string_X509($x509);
	close $fh;
}

sub fingerprint {
	my ($cert, $algo) = @_;
	return lc(Net::SSLeay::X509_get_fingerprint($cert, $algo || DEFAULT_FP_ALGO) =~ tr/://dr);
}

sub gen_identity {	# generate a new privkey - cert identity. cert lifetime in days --> sha256 of the new cert
	my $days = $_[0];
	my $pkey = gen_privkey;
	my $x509 = gen_client_cert($days, $pkey);
	my $sha = fingerprint($x509);
	my $key_out_file = $idents_dir . "/" . $sha . ".key";
	my $crt_out_file = $idents_dir . "/" . $sha . ".crt";
	store_privkey $pkey, $key_out_file;
	store_cert $x509, $crt_out_file;
	return $sha;
}

sub init_crypto {
	@known_hosts = @{$_[0]};
	Net::SSLeay::initialize();
}

sub validate_cert {	# params: certificate, domainname
			# return:
			# (3, date last verified - shorter is better)
			# (2, date first TOFU accepted - longer is better)
			# (1, sha256 of host cert $x509 - for storing)
			# (0, sha256 of host cert $x509 - can be used to update entry in known_hosts)
			# (-1, error string - something else went wrong)
	my ($x509, $domain) = @_;
	# get sha256 fingerprint - it will be needed in all scenarios
	my $algo = $fp_algo || DEFAULT_FP_ALGO;
	my $fp = fingerprint($x509);
	my @kh_match = grep(/^$domain\s+$algo/, @known_hosts);	# is $domain in @known_hosts?
	if (scalar(@kh_match) > 1) {
		return (-1, "more than 1 match in known_hosts for $domain + $algo", undef);
	} elsif (scalar(@kh_match) == 0) {
		# TODO: is ..._get_isotime in local time? or UTC?
		my $new_kh_line = join " ", $domain, $fp_algo || DEFAULT_FP_ALGO, $fp,
			Net::SSLeay::P_ASN1_TIME_get_isotime(Net::SSLeay::X509_get_notAfter($x509)),
			strftime("%Y-%m-%d", localtime);
		append_file $hosts_file, $new_kh_line || clean_die "Error writing $domain entry to $hosts_file";
		push @known_hosts, $new_kh_line;
		return (1, $fg, undef);	# host not known
	} elsif (scalar(@kh_match) == 1) {
		my ($kh_domain, $kh_algo, $kh_fp, $kh_notAfter, $kh_date, $kh_oob) = split /\s+/, $kh_match[0];
		if ($fp eq $kh_fp) {		# TOFU match
			return (2, $kh_date, $kh_notAfter) unless $kh_oob;
			return (3, $kh_date, $kh_notAfter);
		} else {
			return (0, $fp, $kh_notAfter);
		}
	} else {
		return (-1, "unexpected error trying to find $domain + $algo in known_hosts", undef);
	}
}

# see sslcat in /usr/local/libdata/perl5/site_perl/amd64-openbsd/Net/SSLeay.pm
sub sslcat_porcelain { # address, port, message, $crt, $key --> reply / (reply,errs,cert)
	my ($dest_serv, $port, $out_message, $crt_path, $key_path) = @_;
	my ($ctx, $ssl, $got, $errs, $written);

	($got, $errs) = Net::SSLeay::open_proxy_tcp_connection($dest_serv, $port);
	return (wantarray ? (undef, $errs) : undef) unless $got;

	### SSL negotiation
	$ctx = Net::SSLeay::new_x_ctx();
	goto cleanup2 if $errs = Net::SSLeay::print_errs('CTX_new') or !$ctx;
	Net::SSLeay::CTX_set_options($ctx, &Net::SSLeay::OP_ALL);
	goto cleanup2 if $errs = Net::SSLeay::print_errs('CTX_set_options');
	#warn "Cert `$crt_path' given without key" if $crt_path && !$key_path;
	Net::SSLeay::set_cert_and_key($ctx, $crt_path, $key_path) if $crt_path;
	$ssl = Net::SSLeay::new($ctx);
	goto cleanup if $errs = Net::SSLeay::print_errs('SSL_new') or !$ssl;

	# set up SNI (Server Name Indication), see specification item 4
	Net::SSLeay::set_tlsext_host_name($ssl, $dest_serv) || die "failed to set SSL host name for Server Name Indication";

	Net::SSLeay::set_fd($ssl, fileno(Net::SSLeay::SSLCAT_S));
	goto cleanup if $errs = Net::SSLeay::print_errs('set_fd');
	$got = Net::SSLeay::connect($ssl);
	goto cleanup if $errs = Net::SSLeay::print_errs('SSL_connect');
	my $server_cert = Net::SSLeay::get_peer_certificate($ssl);
	Net::SSLeay::print_errs('get_peer_certificate');

	### Connected. Exchange some data (doing repeated tries if necessary).
	($written, $errs) = Net::SSLeay::ssl_write_all($ssl, $out_message);
	goto cleanup unless $written;
	sleep $Net::SSLeay::slowly if $Net::SSLeay::slowly;  # Closing too soon can abort broken servers # TODO: remove?
	($got, $errs) = Net::SSLeay::ssl_read_all($ssl);
	CORE::shutdown Net::SSLeay::SSLCAT_S, 1;  # Half close --> No more output, send EOF to server
cleanup:
	Net::SSLeay::free ($ssl);
	$errs .= Net::SSLeay::print_errs('SSL_free');
cleanup2:
	Net::SSLeay::CTX_free ($ctx);
	$errs .= Net::SSLeay::print_errs('CTX_free');
	close Net::SSLeay::SSLCAT_S;
	return wantarray ? ($got, $errs, $server_cert) : $got;
}

1;
