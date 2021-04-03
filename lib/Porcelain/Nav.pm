package Porcelain::Nav;

use strict;
use warnings;

require Exporter;
our @ISA = qw(Exporter);
our @EXPORT = qw(page_nav);

use Curses;			# for $COLS
use List::Util qw(min max);
use Porcelain::CursesUI;
use Porcelain::Format;

use subs qw(Porcelain::Main::open_about);

my $r;	# holds return value short-term

sub next_match {	# scroll to next match in searchlns; \@sequence, $viewfrom, $displayrows, $render_length --> new $viewfrom
	my ($sequence, $fromln, $rows, $render_length) = @_; 
	if (scalar(@$sequence) < 1) {
		Porcelain::CursesUI::c_prompt_ch "No matches.";
		return undef;
	} else {
		my $centerline = $fromln + int(($rows + 1) / 2);
		if ($centerline >= ${$sequence}[-1]) {	# wrap to beginning of document
			$fromln = max(${$sequence}[0] - int(($rows + 1) / 2), 0);
		} else {
			foreach (@$sequence) {
				if ($_ > $centerline) {
					$fromln = min($_ - int(($rows + 1) / 2), $render_length - $rows - 1);
					last;
				}
			}
		}
		return $fromln;
	}
}

sub page_nav {
	my ($domain, $renderformat, $content) = @_;
	my @formatted;
	undef @Porcelain::Main::links;

	my $viewfrom = 0;	# top line to be shown
	my $render_length;
	my $update_viewport;
	my $reflow_text = 1;
	while (1) {
		if (defined $Porcelain::Main::status_win) {
			delwin($Porcelain::Main::status_win);
		}

		if ($reflow_text) {
			$reflow_text = 0;
			$update_viewport = 1;
			if ($renderformat eq "gemini") {
				gmiformat $content, \@formatted, \@Porcelain::Main::links;
			} elsif ($renderformat eq "plain") {
				plainformat $content, \@formatted;
			}
			$render_length = scalar(@formatted);
		}

		my $displayrows = $LINES - 2;
		my $viewto = min($viewfrom + $displayrows, $render_length - 1);
		if ($update_viewport == 1) {
			c_title_win;
			render $renderformat, $viewfrom, $viewto, \@formatted, \@Porcelain::Main::links, $Porcelain::Main::searchstr;
			refresh;
		}
		$update_viewport = 0;
		my ($c, $fn) = getchar;		# $fn: a function key, like arrow keys etc
		$c = '' if not defined $c;
		$fn = 0x0 if not defined $fn;	# TODO: double-check that this doesn't conflict with any KEY_*
		if ($c eq 'H') {	# show history
			#Porcelain::Main::open_about "about:history";
			return;
		} elsif ($c eq 'i') {	# basic info (position in document, etc.	# TODO: expand, e.g. URL
			my $linesfrom = $viewfrom + 1;
			my $linesto = $viewto + 1;
			my $linespercent = int($linesto / $render_length * 100);
			Porcelain::CursesUI::c_prompt_ch "lines $linesfrom-$linesto/$render_length $linespercent%";
			$update_viewport = 1;
		} elsif ($c eq 'I') {	# advanced info
			# 7: out-of-band verification
			#	- type
			#	- date last renewed
			#	- time since last renewal
			my @info = ("Domain:\t\t\t" . $domain, "Resource:\t\t" . $Porcelain::Main::rq_addr);
			# TODO: order the output to match 'openssl x509 -text -noout -in <cert>'
			push @info, "Server Cert:";
			push @info, "\t\t\tSubject:\t\t" . $Porcelain::Main::host_cert->subject();
			#push @info, "\t\t\tSubject Hash:\t\t" . $Porcelain::Main::host_cert->hash();
			push @info, "\t\t\tEmail:\t\t\t" . $Porcelain::Main::host_cert->email();
			push @info, "\t\t\tIssuer:\t\t\t" . $Porcelain::Main::host_cert->issuer();
			#push @info, "\t\t\tIssuer Hash:\t" . $Porcelain::Main::host_cert->issuer_hash();
			push @info, "\t\t\tNot Valid Before:\t" . $Porcelain::Main::host_cert->notBefore();
			push @info, "\t\t\tNot Valid After:\t" . $Porcelain::Main::host_cert->notAfter();
			#push @info, "\t\t\tModulus:\t\t" . $Porcelain::Main::host_cert->modulus();		# TODO: how useful is modulus? Exponent?
			#push @info, "\t\t\tExponent:\t\t" . $Porcelain::Main::host_cert->exponent();
			push @info, "\t\t\tFingerprint SHA-256:\n\t\t\t" . $Porcelain::Main::host_cert->fingerprint_sha256(); # TODO: improve formatting
			push @info, "\t\t\tCertificate Version:\t" . $Porcelain::Main::host_cert->version();
			push @info, "\t\t\tSignature Algorithm:\t" . $Porcelain::Main::host_cert->sig_alg_name();
			push @info, "\t\t\tPublic Key Algorithm:\t" . $Porcelain::Main::host_cert->key_alg_name();
			if ($Porcelain::Main::host_cert->is_selfsigned()) {
				push @info, "\t\t\tSelf-signed?\t\tYes"; } else { push @info, "\t\t\tSelf-signed?:\t\tNo"; } push @info, "\n\n" . randomart(lc($Porcelain::Main::host_cert->fingerprint_sha256() =~ tr/://dr)); my $infowin = Porcelain::CursesUI::c_fullscr join("\n", @info), "Info";
			undef $c;
			$c = getchar;
			delwin($infowin);
			$update_viewport = 1;
		} elsif ($c eq 'q') {	# quit
			undef $Porcelain::Main::rq_addr;
			return;
		} elsif ($c eq 'r') {	# go to domain root
			$Porcelain::Main::rq_addr = "gemini://" . gem_host($Porcelain::Main::rq_addr);
			return;
		} elsif ($c eq 'R') {	# reload page
			return;
		} elsif ($c eq 'u') {	# up in directories on domain
			my $slashcount = ($Porcelain::Main::rq_addr =~ tr|/||);
			if ($slashcount > 3) {	# only go up if not at root of the domain
				$Porcelain::Main::rq_addr =~ s|[^/]+/[^/]*$||;
				return;
			}
			# TODO: warn if can't go up
		} elsif ($c eq 'v') {	# verify server identity
			my $domain = gem_host $Porcelain::Main::rq_addr;
			# ask for SHA-256, manual confirmation, or URL
			undef $r;
			until ($r) {
				$r = Porcelain::CursesUI::c_pad_str "Enter SHA-256, URL (for third-party verification), or [M] for manual mode: ";
			}
			chomp $r;
			$r = lc $r;
			if ($r eq "m") {			# manual mode
				my $match_win_width = max(int($COLS / 1.25), 22);
				my $match_win_height = max(int($displayrows / 1.25), 12);
				my $match_win = newwin($match_win_height, $match_win_width, int(($displayrows - $match_win_height) / 2), int(($COLS - $match_win_width) / 2)); 
				box($match_win, 0, 0);
				addstr($match_win, 1, 1, $Porcelain::Main::host_cert->fingerprint_sha256());
				addstr($match_win, 3, 1, randomart(lc($Porcelain::Main::host_cert->fingerprint_sha256() =~ tr/://dr)));
				addstr($match_win, $match_win_height - 2, 1, "Compare with SHA-256 fingerprint obtained from a credible source. Does it match?");
				refresh($match_win);
				$r = getch;
				unless (lc($r) eq 'y') {
					return;
				}
				# TODO: store the $sha256 (from $Porcelain::Main::host_cert) in known_hosts
			} elsif ($r =~ tr/://dr =~ /^[0-9a-f]{64}$/) {	# SHA-256, can be 01:AB:... or 01ab...
				if ($r eq lc($Porcelain::Main::host_cert->fingerprint_sha256() =~ tr/://dr)) {
					Porcelain::CursesUI::clean_exit "SHA-256 match";
				} else {
					Porcelain::CursesUI::clean_exit "SHA-256 mismatch";
				}
				# TODO:
				#	If it matches, should turn green (or stay green).
				#	If it doesn't match, show warning/error, and ask if user is sure that key entered is correct
				#	If entered key is correct, host will now be red
				#	If was not correct or not sure, offer entry of a new key or bail out and stay yellow
				#	Store host and user-entered SHA-256 if A) match, or B) confirmed correct key with mismatch
				#	otherwise, remove entry; staying yellow
			} elsif (not $r =~ /\s/) {		# URL	# TODO: refine?
				# TODO: implement fetching an SHA-256, pubkey (other?)
				Porcelain::CursesUI::clean_exit "Third-party OOB verification not yet implemented; URL provided: $r";
			} else {
				Porcelain::CursesUI::clean_exit "Invalid response: $r";
			}
			# TODO: implement creating the record and storing it
		} elsif ($c eq "]") {	# 'next' gemini://gemini.circumlunar.space/users/solderpunk/gemlog/gemini-client-navigation.gmi
			if (defined $Porcelain::Main::chosen_link && $Porcelain::Main::chosen_link < scalar(@Porcelain::Main::last_links)-1 && defined $Porcelain::Main::last_links[$Porcelain::Main::chosen_link+1]) {
				$Porcelain::Main::chosen_link++;
				$Porcelain::Main::rq_addr = $Porcelain::Main::last_links[$Porcelain::Main::chosen_link];
				return;
			}	# TODO: warn/error if no such link
		} elsif ($c eq "[") {	# 'previous'
			if (defined $Porcelain::Main::chosen_link && $Porcelain::Main::chosen_link > 0 && defined $Porcelain::Main::last_links[$Porcelain::Main::chosen_link-1]) {
				$Porcelain::Main::chosen_link--;
				$Porcelain::Main::rq_addr = $Porcelain::Main::last_links[$Porcelain::Main::chosen_link];
				return;
			}	# TODO: warn/error if no such link
		} elsif ($c eq "\cH" || $fn == KEY_BACKSPACE) {
			if (scalar(@Porcelain::Main::back_history) > 0) {
				push @Porcelain::Main::forward_history, $Porcelain::Main::rq_addr;
				$Porcelain::Main::rq_addr = pop @Porcelain::Main::back_history;
				return;
			}
		} elsif ($c eq "\cL") {	# forward in history
			if (scalar(@Porcelain::Main::forward_history) > 0) {
				push @Porcelain::Main::back_history, $Porcelain::Main::rq_addr;
				$Porcelain::Main::rq_addr = pop @Porcelain::Main::forward_history;
				return;
			}
		} elsif ($fn eq KEY_RESIZE) {	# terminal has been resized
			$reflow_text = 1;
		} elsif ($c eq ' ' || $fn == KEY_NPAGE) {
			if ($viewto < $render_length - 1) {
				$update_viewport = 1;
				$viewfrom = min($viewfrom + $displayrows, $render_length - $displayrows - 1);
			}
		} elsif ($c eq 'b' || $fn == KEY_PPAGE) {
			if ($viewfrom > 0) {
				$update_viewport = 1;
				$viewfrom = max($viewfrom - $displayrows, 0);
			}
		} elsif ($c eq 'j' || $fn == KEY_DOWN) {
			if ($viewto < $render_length - 1) {
				$update_viewport = 1;
				$viewfrom++;
			}
		} elsif ($c eq 'k' || $fn == KEY_UP) {
			if ($viewfrom > 0) {
				$update_viewport = 1;
				$viewfrom--;
			}
		} elsif ($c eq 'K' || $fn == KEY_HOME) {
			if ($viewfrom > 0) {
				$update_viewport = 1;
				$viewfrom = 0;
			}
		} elsif ($c eq 'J' || $fn == KEY_END) {
			if ($viewto < $render_length - 1) {
				$update_viewport = 1;
				$viewfrom = $render_length - $displayrows - 1;
			}
		} elsif ($c eq 'n') {
			my $viewfrom_new = next_match \@Porcelain::Main::searchlns, $viewfrom, $displayrows, $render_length;
			if (defined $viewfrom_new) {
				$viewfrom = $viewfrom_new;
			}
			$update_viewport = 1;
		} elsif ($c eq 'o') {
			push @Porcelain::Main::back_history, $Porcelain::Main::rq_addr;	# save last address to back_history
			$Porcelain::Main::rq_addr = Porcelain::CursesUI::c_prompt_str("open: ");	# not allowing relative links
			if (not $Porcelain::Main::rq_addr =~ m{:}) {
				$Porcelain::Main::rq_addr = "gemini://" . $Porcelain::Main::rq_addr;
			}
			return;
		} elsif ($c eq ':') {	# TODO: implement long option commands, e.g. help...
			my $s = Porcelain::CursesUI::c_prompt_str(": ");
			# 'up'/'..'
			# 'root'/'/'
			# 'next', 'previous'
			# 'back', 'forward'
			addstr(0, 0, "You typed: " . $s);
			getch;
			$update_viewport = 1;
			Porcelain::CursesUI::clean_exit;
		} elsif ($c eq '/') {
			$Porcelain::Main::searchstr = Porcelain::CursesUI::c_prompt_str("search: ");
			@Porcelain::Main::searchlns = grep { $formatted[$_] =~ /$Porcelain::Main::searchstr/i } 0..$#formatted;
			my $viewfrom_new = next_match \@Porcelain::Main::searchlns, $viewfrom, $displayrows, $render_length;
			if (defined $viewfrom_new) {
				$viewfrom = $viewfrom_new;
			}
			$update_viewport = 1;
		} elsif ( $c =~ /\d/ ) {
			Porcelain::CursesUI::c_statusline "open link: $c - " . $Porcelain::Main::links[$c-1];
			if (scalar(@Porcelain::Main::links) >= 10) {
				timeout(500);
				my $keypress = getch;
				if (defined $keypress && $keypress =~ /\d/ && $keypress >= 0) {	# ignore non-digit input
					$c .= $keypress;
					Porcelain::CursesUI::c_statusline "open link: $c - " . $Porcelain::Main::links[$c-1];
					if (scalar(@Porcelain::Main::links) >= 100) {	# supports up to 999 links in a page
						undef $keypress;
						my $keypress = getch;
						if (defined $keypress && $keypress =~ /\d/ && $keypress >= 0) {
							$c .= $keypress;
						}
					}
				}
				timeout(-1);
			}
			unless ($c <= scalar(@Porcelain::Main::links)) {
				delwin($Porcelain::Main::status_win);
				Porcelain::CursesUI::c_err "link number outside of range of current page: $c";
				return;
			}
			$Porcelain::Main::chosen_link = $c-1;
			@Porcelain::Main::last_links = @Porcelain::Main::links;	# TODO: last links needs to store absolute links, or use last rq_addr from history
			Porcelain::CursesUI::c_statusline "open link: $c - " . $Porcelain::Main::last_links[$Porcelain::Main::chosen_link];
			push @Porcelain::Main::back_history, $Porcelain::Main::rq_addr;	# save last rq_addr to back_history
			foreach (@Porcelain::Main::last_links) {
				$_ = Porcelain::Main::url2absolute($Porcelain::Main::rq_addr, $_);
			}
			$Porcelain::Main::rq_addr = $Porcelain::Main::last_links[$Porcelain::Main::chosen_link];
			return;
		}
	}
}

1;
