#!/usr/bin/perl
use strict;
use warnings;

use Getopt::Euclid;
use feature ':5.10';

use Geo::OSM::Tiles qw( :all );
use LWP::UserAgent;
use Digest::MD5 qw(md5);
use PDL;
use PDL::Fit::Linfit;


my $pi = 3.14159265359;


my $userAgent = LWP::UserAgent->new;




my $center_lat = $ARGV{'--center'}{lat};
my $center_lon = $ARGV{'--center'}{lon};
my $zoom       = $ARGV{'--zoom'};

# I want radius in meters
my ($rad,$unit) = $ARGV{'--rad'} =~ /([0-9\.]+)(.*?)$/;
if   ($unit =~ /mile/) { $rad *= 5280 * 12 * 2.54 / 100; }
elsif($unit =~ /km/ )  { $rad *= 1000; }

my $Rearth = 6371000.0; # meters


my @lat = ($center_lat - $rad/$Rearth * 180.0/$pi,
           $center_lat + $rad/$Rearth * 180.0/$pi );
my @lon = ($center_lon - $rad/$Rearth * 180.0/$pi * cos($center_lat * $pi/180.0),
           $center_lon + $rad/$Rearth * 180.0/$pi * cos($center_lat * $pi/180.0) );

my @tilex = map { lon2tilex($_, $zoom ) } @lon;
my @tiley = map { lat2tiley($_, $zoom ) } @lat;

my @montage_tile_list;
for my $y ($tiley[1]..$tiley[0]) # vertical tiles are ordered backwards because
                                 # that's how the mapping function works
{
    for my $x ($tilex[0]..$tilex[1])
    {
        my $path = tile2path($x, $y, $zoom);
        my $tileurl = "http://tile.openstreetmap.org/$path";
        my $filename = "tile_${x}_${y}_${zoom}.png";


        my @get_args = (":content_file" => $filename);

        if( !$ARGV{'--nocache'} && -r $filename )
        {
            # a local file exists AND we weren't asked to ignore local caches

            # compute the checksum of the local file
            local  $/ = undef;
            open TILE, $filename;
            my $md5_cache = join('', unpack('H*', md5(<TILE>)));
            close TILE;

            # tells server to only send data if needed
            push @get_args, ('if-none-match' => "\"$md5_cache\"" );
        }

        say STDERR "Downloading $tileurl";
        $userAgent->get($tileurl, @get_args)
          or die "Error downloading '$tileurl'";

        push @montage_tile_list, $filename;
    }
}

my $width  = $tilex[1] - $tilex[0] + 1;
my $height = $tiley[1] - $tiley[0] + 1;

my $montage_filename = "montage_${center_lat}_${center_lon}_$ARGV{'--rad'}_$zoom.png";
system("montage @montage_tile_list -tile ${width}x${height} -geometry +0+0 $montage_filename") == 0
  or die "Error running montage: $@";



# I now generate a gnuplot scrript. Here I require dx,dy,centerx,centery to
# properly scale, position the montage

# derived from the source of Geo::OSM::Tiles
my $dx = 360 * 2**(-$zoom) / 256;
my $centerx = ($tilex[0]*256 + $tilex[1]*256 + 255) / 2;
$centerx = $centerx/256 * 2**(-$zoom) * 360 - 180;

# sources of Geo::OSM::Tiles say that
sub px_from_lat
{
    my $lat = shift;
    return (1 - log(tan($lat) + 1.0/cos($lat))/$pi)/2 * 2**$zoom * 256;
}
# This is (clearly) non-linear, but for small spans of latitude should be linear
# enough. I sample this function through my range, apply linear least squares to
# fit a line to it, and get dy and centery from this line
my $lat_fit = zeros(10)->xlinvals($lat[0]*$pi/180, $lat[1]*$pi/180);
my $px_fit= pdl( map { px_from_lat($_) } $lat_fit->list );
my ($fit, $coeffs) = linfit1d($lat_fit, $px_fit, PDL::cat( $lat_fit->ones,
                                                           $lat_fit));
my @c = $coeffs->list;

# I now have px ~ $c[0] + lat*c[1];

my $centery = ($tiley[0]*256 + $tiley[1]*256 + 255) / 2; # px
$centery = ($centery - $c[0]) / $c[1] * 180/$pi;
my $dy = -1.0/$c[1] * 180.0/$pi; # negative because gnuplot inverts y by
                                 # default, so the negative slope this thing has
                                 # is not needed


my $gnuplot_script = <<EOF;
attenuation = 1.5
set size ratio -1./cos($center_lat * pi/180.0)
plot "$montage_filename" binary filetype=png dx=$dx dy=$dy center=($centerx,$centery) using (\$1/attenuation):(\$2/attenuation):(\$3/attenuation) with rgbimage notitle
EOF

my $gpfilename = $montage_filename;
$gpfilename =~ s/png$/gp/;

open GP, '>', $gpfilename;
print GP $gnuplot_script;
close GP;

say "Done! Gnuplot script '$gpfilename' uses the image '$montage_filename'";



__END__

=head1 NAME

osmgnuplot.pl - Download OSM tiles, and make a gnuplot script to render them

=head1 SYNOPSIS

 $ osmgnuplot.pl --center 34.12,-118.34 --radius 20miles --zoom 16

=head1 DESCRIPTION

This script downloads OSM tiles and generates a gnuplot script to render them.
While this in itself is not useful, the gnuplot script can be expanded to plot
other things on top of the map, to make it easy to visualize geospatial data.

This script tries to detect already-downloaded tiles by computing a checksum of
a candidate cache local file, and comparing to what the server tells us in a
header. This can be turned off with --nocache

=head1 REQUIRED ARGUMENTS

=over

=item --center <lat>,<lon>

Center point

=for Euclid:
  lat.type: number
  lon.type: number

=item --rad <radius>

How far around the center to query. This must include units (no whitespace
between number and units).

=for Euclid:
  radius.type: /[0-9]+(?:\.[-9]*)?(?:miles?|km|m)/

=item --zoom <zoom>

The OSM zoom level

=for Euclid:
  zoom.type: integer, zoom > 0 && zoom <= 18

=for Euclid:
  radius.type: /[0-9]+(?:\.[-9]*)?(?:miles?|km|m)/

=back

=head1 OPTIONAL ARGUMENTS

=over

=item --nocache

By default we don't download tiles we have already (based on a checksum). With
this option, we suppress this logic and always download fresh tiles.

=back

=head1 AUTHOR

Dima Kogan, C<< <dima@secretsauce.net> >>
