package Porcelain::Crypto;

use strict;
use warnings;

require Exporter;
our @ISA = qw(Exporter);
our @EXPORT = qw(gen_client_cert gen_identity gen_privkey store_cert store_privkey);

my $default_rsa_bits = 2048;
my $rsa_exponent = 65537;

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

1;
