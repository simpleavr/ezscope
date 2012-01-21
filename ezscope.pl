#!/usr/bin/perl -w

#
# giftware, as is, no warranty, restricted to hobby use
# you cannot use this software for commercial gains w/o my permission
# 
# if u are building software releasing it based on this,
# u should retain this message in your source and cite it's origin
# otherwise just take whatever code snipplets you need
#
# simpleavr@gmail.com
# www.simpleavr.com
# 
# Nov 2010 c chung
#
# this is the host side (linux) data visualization perl script for
# the ezrfm spectrum analyzer
#
# you will need to use cpan to install
#   Device::SerialPort, Time::HiRes and Tk
#
# have your launchpad connected to pc (ubuntu 10.04)
# and run this script in a terminal
# if u are talking to a ftdi or nokia phone cable
# u need to change the ttyACM0 device to ttyUSB0 or something
#

use Device::SerialPort;
use Time::HiRes qw/usleep/;
use Tk;
use strict;

my $window = MainWindow->new;

$window->title('Launchpad Scope');
$window->Label(-text => 'www.simpleavr.com', -anchor => 'e')->pack(-expand => 1, -fill => 'x');
$window->configure(-background => 'dark green');

my %color = (
	bg => 'black',
	lo => '#339933',
	rs => 'green',
	ls => '#339933',
	tx => '#660000',
	at => 'red',
	hl => 'cyan',
	mk => 'yellow',
);

my ($min_step, $max_step) = (0, 4096);
my %rss_bkt = ();
my @yleg = (' ', 'ch0', 'ch1', 'ch2', 'ch3', 'ch4', 'ch5');

my %ruler = (
	1 => [430, 0.0025],
	2 => [860, 0.0050],
	3 => [900, 0.0075],
	);

my ($start, $skip) = ($min_step, $max_step/10);

my ($max_level) = (64);

my %opts = (
	band	=>  3,
	sweeps	=>	4,
	zoom	=>	1,
	amplify	=>	1,
	skip    =>  4,
	peak	=>  0,
);
 
my %range = (
	#
	# these are the setting on the main screen
	# . upon 'mouse-over', related text will be brightened
	# . upon 'mouse-click', we cycle the possible setting values
	# . based on the following table we would
	#   . redraw main screen (tk canvas)
	#   . download parameter to mcu via uart
	# . values are numerics, but some maps to screen legends
	#
	#           [min, mix, redraw, download, [screen legends]]
	#
	band  	=>	[1,  3, 'reload', 1, ['', '433Mhz', '868Mhz', '915Mhz' ]],
	sweeps	=>	[1,  8, 'reload', 0],
	zoom	=>	[1,  4, 'reload', 0],
	amplify	=>	[1,  4, 'reload', 0],
	skip 	=>	[0,  5, 'reload', 1 ,[
									'7.5Khz Sampling', # value 0
									' 15Khz Sampling', # value 1, etc
									' 30Khz Sampling',
									' 60Khz Sampling',
									'120Khz Sampling',
									'240Khz Sampling', ]],
	peak   	=>	[0,  2, 'reload', 0, ["Bars", "Peak Graph", "Peak Hold" ]],
);

%range = ();

my %o = (
	step_x	=> 48,
	step_y	=> 48,
	xsteps	=> 8,
	ysteps	=> 4,
);

my $port = ();
my $graph = ();
my (%peak, %mark);
my $signal = '';
my $header = ();

my ($xrange, $yrange) = ($o{xsteps} * $o{step_x}, $o{ysteps} * $o{step_y});
#________________________________________________________________________________
sub fake_logic {
	my ($beams, $noise, $noise_range) = (4, 4, 8);
	%rss_bkt = ();
	for (0..$beams) {
		my $idx = rand($max_step-$min_step);
		$idx *= $xrange / $max_step;
		$rss_bkt{$idx} = rand($max_level / 4) * $opts{amplify};
		for (0..$noise) {
			$rss_bkt{$idx+rand($noise_range)-$noise_range/2} = 
				rand($max_level / 4) * $opts{amplify};
		}
	}
}

my @graph_objs = ();
#________________________________________________________________________________
sub graph_it;

sub graph_it {
	my $command = shift @_;

	$command or $command = '-';

	$command eq 'reload' && $graph and do {
		$graph->packForget;
		$graph = ();
	};

	$skip = $max_step/$o{xsteps}*(1/$opts{zoom});
	$start < $min_step and $start = $min_step;
	($start + $max_step/$opts{zoom}) > $max_step and $start = $max_step - $max_step/$opts{zoom};

	$graph or do {
		$graph = $window->Canvas(
			-width	=> $o{step_x} * ($o{xsteps}+2),
			-height	=> $o{step_y} * ($o{ysteps}+2),
			-background => $color{bg});

		#__________ paint background
		$graph->createRectangle(
				0, 0,
				$o{step_x} * ($o{xsteps}+2), $o{step_y} * ($o{ysteps}+2),
				-fill => $color{bg});

		my $txt_pos = $o{step_y} + 20;
		my $pos_add = $o{step_y};
		for (keys %range) {
			my $txt_id = $graph->createText($xrange + $o{step_x}, $txt_pos,
				-text => 
				$range{$_}->[4]
				? $range{$_}->[4]->[$opts{$_}]
				: ucfirst($_) . " $opts{$_}"
				,
				-font => 'lucidasanstypewriter-16',
				-fill => $color{tx}, -anchor => 'e', -justify => 'right');
			$txt_pos += $pos_add;
			my $item_then = $_;
			my $txt_then = $txt_id;
			#______ callback for mouse-over, will brighten related text
			$graph->bind($txt_id, '<Enter>', => sub {
					my $self = shift @_;
					my $id = $txt_id;
					$self->itemconfigure($id, -fill => $color{at});
				});
			#______ callback for mouse-over leaving, darkens related text
			$graph->bind($txt_id, '<Leave>', => sub {
					my $self = shift @_;
					my $id = $txt_id;
					$self->itemconfigure($id, -fill => $color{tx});
				});
			#______ callback for clicks, cycle thru range of accepted values
			$graph->bind($txt_id, '<ButtonRelease-1>', => sub {
					my $self = shift @_;
					my $setting = $item_then;
					print $setting;
					$opts{$setting}++;
					$opts{$setting} > $range{$setting}->[1] and
						$opts{$setting} = $range{$setting}->[0];
					graph_it($range{$setting}->[2]);
					#____ see if we need to send parameters to launchpad
					$port && $range{$setting}->[3] and do {
						$port->write(pack("C", 0x00));
						# allow sometime for mcu to process last command
						# it's on software uart only
						usleep 50000;		
						$port->write(pack('C', 0x20 | $opts{skip}));
						usleep 50000;
						$port->write(pack('C', 0x30 | $opts{band}));
						usleep 50000;
						$port->write(pack("C", 0x01));
					};
				});
		}
		#__________ horizontal lines
		for my $idx (0..$o{ysteps}) {
			for my $adv (0..$o{xsteps}) {
				$graph->createLine(
					$o{step_x}*($adv+1)-3, ($idx+1) * $o{step_y}, 
					$o{step_x}*($adv+1)+4, ($idx+1) * $o{step_y}, 
					-fill => $color{lo});
			}
			$graph->createText($o{step_y}-6, ($idx+1) * $o{step_y}, 
				-text => "$yleg[$idx]", -fill => $color{lo}, -anchor => 'e');
		}

		#__________ vertical lines
		my ($base, $step) = @{$ruler{$opts{band}}};
		for my $idx (0..$o{xsteps}) {
			for my $adv (0..$o{ysteps}) {
				$graph->createLine(
					($idx+1) * $o{step_x}, $o{step_y}*($adv+1)-3,
					($idx+1) * $o{step_x}, $o{step_y}*($adv+1)+4,
					-fill => $color{lo});
			}
			#$graph->createText(($idx+1) * $o{step_x}, $o{step_y} * ($o{ysteps}+1) + 4,
			#	-text =>  sprintf("%.1lf", $base + (($start + $skip * ($idx)) * $step)),
			#	-fill => $color{lo}, -anchor => "n");
		}

		1==0 and do {
		#__________ scale box
		$graph->createRectangle(
			$o{step_x}, ($o{ysteps}+1) * $o{step_y}+25, 
			($o{xsteps}+1) * $o{step_x}, ($o{ysteps}+1) * $o{step_y}+35, 
			);

		#__________ occupied range
		my ($rb, $re, $rs) = ($o{step_x}, $o{step_x} + ($o{step_x} * $o{xsteps} * (1/$opts{zoom})), 0);
		$start and
			$rs += $o{xsteps} * $o{step_x} * $start / $max_step;
		$graph->createRectangle(
			$rb + $rs, ($o{ysteps}+1) * $o{step_y} + 25, 
			$re + $rs, ($o{ysteps}+1) * $o{step_y} + 35, 
			-fill => $color{rs});
		};

		@graph_objs = ();
	};

	for (@graph_objs) {
		$graph->delete($_);
	}

	@graph_objs = ();

	my @ch = ('', '', '', '',);
	my $i = 0;
	foreach (split //, $signal) {
		$ch[$i++] .= $_;
		$i>3 and $i = 0;
	}

	$i = 5;
	foreach (@ch) {
		my $sig = $_;
		my ($x, $y) = ($o{step_x}, $o{step_y} * $i--);
		my @visual = ();

		my $ly = $y;
		my $s = 0;
		#$signal =  '1110011100001101' x 15;
		#print "v---------------" x 15, "\n";
		#print "$sig\n";
		$signal and do {
			$sig =~ m/^1/ and $s = 32;
			$sig =~ s/0/L/g;
			$sig =~ s/(1+)/length($1).','/eg;
			$sig =~ s/(L+)/length($1).','/eg;
			$sig =~ s/.$//;
			#print "$sig\n";
			foreach (split /,/, $sig) {
				@visual and push @visual, ($x, $y-$s);
				push @visual, ($x, $y-$s);
				$x += $_ * 2;
				push @visual, ($x, $y-$s);
				$s = $s ? 0 : 32;
			}
		};

		@visual and do {
			my $obj = $graph->createLine(@visual, -fill => $color{rs});
			push @graph_objs, $obj;
		};
	};

	$command eq 'reload' and $graph->pack;
}

#________________________________________________________________________________
#
# for ti launchpad use ttyACM0, for others u should know your device name
#

graph_it('reload');
$port = Device::SerialPort->new("/dev/ttyACM0") or print "port open failed...\n";
#
# change ttyACM0 to whatever device name you got from your serial comm
#
#$port = Device::SerialPort->new("/dev/ttyUSB0") or print "port open failed...\n";

#________________________________________________________________________________

# this following is the lower toolbar and toolbar buttons
#

my $toolbar = $window->Frame()->pack(-side => 'bottom', -expand => 1, -fill => 'x');
$toolbar->Button(-text => 'Dismiss', -command => sub {
		$port and do {
			$port->write(pack("C", 0x00));
			$port->close;
			print "\n";
		};
		exit;
	})->pack(-side => 'right');

$toolbar->Button(-text => 'Start', -command => sub { $port and $port->write(pack("C", 0x01)); })->pack(-side => 'right');
$toolbar->Button(-text => 'Hold', -command => sub { $port and $port->write(pack("C", 0x00)); })->pack(-side => 'right');
$toolbar->Button(-text => 'Mark', -command => sub { 
		%mark = %peak;
		$opts{peak} = 0; 
		graph_it('reload');
	})->pack(-side => 'right');

$toolbar->Button(-text => '>>', -command => sub { $start += 100; graph_it('reload'); })->pack(-side => 'right');
$toolbar->Button(-text => '<<', -command => sub { $start -= 100; graph_it('reload'); })->pack(-side => 'right'); 

#__________ initialize comm

$port and do {
	$port->databits(8);
	#
	# launchpad is limited to 9600
	# for other serial solutions, u can make it higher
	# be sure to change mps430 source and redo firmware
	#
	$port->baudrate(9600);
	$port->parity("none");
	$port->stopbits(1);
	$port->read_char_time(10);
	$port->read_const_time(10);
	$port->write_drain;
	$port->write(pack('C', 0x01));
	$port->write(pack('C', 0x20 | $opts{skip}));
	$port->write(pack('C', 0x30 | $opts{band}));
};

my $cur_sweeps = 0;

$window->repeat(50, sub {
		while ($port) {
			my ($cnt, $saw) = $port->read(2);
			$cnt or return;
			$cnt == 2 and do {
				my $inp = unpack("S", $saw);
				#printf "%04x\n", $inp;
				if (!$header) {
					$header = $inp;
					printf "hdr %04x, %ld\n", $header, $header;
				}
				else {
					if ($inp == 0x1234) {
						#print "----\n";
						#print "$signal\n";
						graph_it;
						$signal = '';
						$header = ();
					}
					else {
						$signal .= unpack("B16", $saw);
					}
				}
			};
		}
	});

#$port or die "cannot open serial port\n";

# if we can't open the port, we will fake some data, handly to debug the gui
#
#$port or $window->repeat(1000, sub { fake_logic; graph_it; });

MainLoop;

