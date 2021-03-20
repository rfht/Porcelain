package Porcelain::Crypto;

use strict;
use warnings;

require Exporter;
our @ISA = qw(Exporter);
our @EXPORT = qw(gen_client_cert gen_identity gen_privkey store_cert store_privkey validate_cert sslcat_porcelain);

use subs qw(c_warn);

my $default_fp_algo = "SHA-256";
my $default_rsa_bits = 2048;
my $rsa_exponent = 65537;
my $r;		# hold short-term return values

sub gen_privkey {	# --> return private key
	# see https://stackoverflow.com/questions/256405/programmatically-create-x509-certificate-using-openssl
	my $pkey = Net::SSLeay::EVP_PKEY_new();
	my $rsa = Net::SSLeay::RSA_generate_key($default_rsa_bits, $rsa_exponent) or die;	# returns value corresponding to openssl's RSA structur; other optional args: $perl_cb, $perl_cb_arg
	Net::SSLeay::EVP_PKEY_assign_RSA($pkey, $rsa) or die;
	#Net::SSLeay::RSA_free($rsa);	# TODO: not needed here?
	#Net::SSLeay::EVP_PKEY_free($pkey);	# TODO: not needed here?
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
	#Net::SSLeay::X509_set_subject_name($x509, $sname);
	Net::SSLeay::X509_set_issuer_name($x509, $sname);	# subject name and issuer name are the same - self-signed cert
	Net::SSLeay::X509_sign($x509, $pkey, Net::SSLeay::EVP_sha1());	# TODO: is SHA-1 a reasonable algorithm here?
	#Net::SSLeay::X509_free($x509);	# TODO: needed here?
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

sub gen_identity {	# generate a new privkey - cert identity. cert lifetime in days --> SHA-256 of the new cert
	my $days = $_[0];
	my $pkey = gen_privkey;
	my $x509 = gen_client_cert($days, $pkey);
	my $sha = Crypt::OpenSSL::X509->new_from_string(Net::SSLeay::PEM_get_string_X509($x509))->fingerprint_sha256();
	$sha = lc($sha =~ tr/://dr);
	my $key_out_file = $Porcelain::Main::idents_dir . "/" . $sha . ".key";
	my $crt_out_file = $Porcelain::Main::idents_dir . "/" . $sha . ".crt";
	store_privkey $pkey, $key_out_file;
	store_cert $x509, $crt_out_file;
	return $sha;
}

sub validate_cert {	# certificate, domainname --> undef: ok, <any string>: ERROR (message in string)
	# TODO: add optional notBefore/notAfter checks
	# TODO: allow temporarily accepting new/changed certificates?
	my $domainname = $_[1];
	foreach (@Porcelain::Main::known_hosts) {
		my $this_host = $_;
		if (substr($this_host, 0, length($domainname)) eq $domainname) {
			($Porcelain::Main::kh_domain, $Porcelain::Main::kh_algo, $Porcelain::Main::kh_serv_hash, $Porcelain::Main::kh_oob_hash, $Porcelain::Main::kh_oob_source, $Porcelain::Main::kh_oob_date) = split " ", $this_host;
			last;
		}
	}
	if ($Porcelain::Main::kh_serv_hash) {
		# cert is known, does cert still match (TOFU)?
		#my ($fp_algo, $fp) = (split(" ", $match[0]))[1,2];	# $fp_algo: fingerprint algorithm (SHA-256), $fp: fingerprint
		if ($Porcelain::Main::kh_algo eq "SHA-256") {
			if (lc($Porcelain::Main::url_cert->fingerprint_sha256() =~ tr/://dr) eq $Porcelain::Main::kh_serv_hash) {
				return undef;
			} else {
				return "fingerprint mismatch";
			}
		}
		return "unsupported fingerprint algorithm: $Porcelain::Main::kh_algo";
	}
	# TODO: allow config setting to automatically accept unknown hosts without prompt
	$r = '';
	until ($r =~ /^[SsAa]$/) {
		$r = c_warn "Unknown host: $domainname. [S]ave to known_hosts and continue, or [A]bort?";
	}
	if ($r =~ /^[Aa]$/) {
		return "Unknown host: $domainname, user aborted";
	}
	# New Host. add to @known_hosts and write to $hosts_file
	($Porcelain::Main::kh_domain, $Porcelain::Main::kh_algo, $Porcelain::Main::kh_serv_hash) = ($domainname, $default_fp_algo, lc($Porcelain::Main::url_cert->fingerprint_sha256() =~ tr/://dr));
	open (my $fh, '>>', $Porcelain::Main::hosts_file) or die "Could not open file $Porcelain::Main::hosts_file";
	if ($default_fp_algo eq "SHA-256") {
		my $kh_line = $Porcelain::Main::kh_domain . ' ' . $Porcelain::Main::kh_algo . ' ' . $Porcelain::Main::kh_serv_hash;
		push @Porcelain::Main::known_hosts, $kh_line;
		$fh->print($kh_line . "\n");
		close $fh;
		return undef;
	}
	close $fh;
	return "unsupported fingerprint algorithm: $default_fp_algo";
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
