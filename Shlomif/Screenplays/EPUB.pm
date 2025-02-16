package Shlomif::Screenplays::EPUB;

use strict;
use warnings;
use 5.014;

use Carp       ();
use Path::Tiny qw/ path /;

use utf8;

use App::Gezer ();
use MooX       qw/ late /;

use XML::LibXML               ();
use XML::LibXML::XPathContext ();

use JSON::MaybeXS qw( );

my $jsonner = JSON::MaybeXS->new( utf8 => 1 );

use HTML::Widgets::NavMenu::EscapeHtml qw( escape_html );

use Getopt::Long qw( GetOptions );

use File::Copy qw( copy );

has [ 'filename', 'gfx', 'out_fn', 'epub_basename', ] =>
    ( is => 'rw', isa => 'Str', );
has script_dir => (
    is      => 'ro',
    default => sub { return path($0)->parent(2)->absolute; },
);

has [ 'target_dir', ] => ( is => 'rw', );
has 'images' => ( is => 'ro', isa => 'HashRef[Str]', default => sub { +{}; }, );
has 'should_minify' => ( is => 'ro', default => 1, );

has 'common_json_data' => (
    isa       => 'HashRef',
    is        => 'ro',
    'default' => sub {
        return +{
            contents => [
                {
                    "type"   => "toc",
                    "source" => "toc.xhtml",
                },
                {
                    type   => 'text',
                    source => "scene-*.xhtml",
                },
            ],
            toc => {
                "depth"    => 2,
                "parse"    => [ "text", ],
                "generate" => {
                    "title" => "Index"
                },
            },
            guide => [
                {
                    type  => "toc",
                    title => "Index",
                    href  => "toc.xhtml",
                },
            ],
        };
    },
);

eval {
    require Inline;
    Inline->import( 'Python' => <<'EOF');
from rebookmaker import EbookMaker
from zipfile import ZIP_DEFLATED

_maker = EbookMaker(compression=ZIP_DEFLATED)

def _my_decode(s):
    try:
        d = s.decode('utf-8')
        return d
    except Exception as e:
        if (isinstance(s, str)):
            return s
        # traceback.print_tb(sys.exc_info()[2])
        raise e

def _my_make_epub(json_filename, filename):
    try:
        _maker.make_epub(_my_decode(json_filename), _my_decode(filename), )
    except Exception as e:
        import traceback
        import sys
        traceback.print_tb(sys.exc_info()[2])
        raise e
EOF
};

if ($@)
{
    *_my_make_epub = sub {
        my ( $json_abs, $epub_fn, ) = @_;
        my @cmd = (
            ( $ENV{REBOOKMAKER} || "rebookmaker" ),
            "--output", $epub_fn, $json_abs,
        );
        system(@cmd)
            and die "cannot run rebookmaker <<@cmd>> - $!";
        return;
    };
}

sub json_filename
{
    my ($self) = @_;

    return $self->epub_basename . '.json';
}

my $xhtml_ns = "http://www.w3.org/1999/xhtml";

sub _get_xpc
{
    my ($node) = @_;
    my $xpc = XML::LibXML::XPathContext->new($node);
    $xpc->registerNs( "xhtml", $xhtml_ns );

    return $xpc;
}

sub run
{
    my ($self) = @_;

    my $out_fn;

    GetOptions( "output|o=s" => \$out_fn, )
        or Carp::confess("GetOptions failed - $!");

    $self->out_fn($out_fn);

    # Input the filename
    my $filename = shift(@ARGV)
        or die "Give me a filename as a command argument: myscript FILENAME";

    $self->filename($filename);

    my $target_dir =
        $self->target_dir
        ? path( $self->target_dir )
        : scalar( Path::Tiny->tempdir() );
    $self->target_dir($target_dir);

    # Prepare the objects.
    my $xml       = XML::LibXML->new;
    my $root_node = $xml->parse_file($filename);
    my @scene_bns;
    my $images = +{};
    {
        my $xpc = _get_xpc($root_node);

        foreach my $img ( $xpc->findnodes(q{//xhtml:img/@src}) )
        {
            my $url = $img->textContent();
            $url =~ s#\A(?:\./)?images/##
                or die "wrong prefix img src=<$url>";
            $images->{$url} = "images/$url";

        }

        my $scenes_list = $xpc->findnodes(
q{//xhtml:main[@class='screenplay']/xhtml:section[@class='scene']/xhtml:section[@class='scene' and xhtml:header/xhtml:h2]}
        ) or die "Cannot find top-level scenes list.";

        my $idx = 0;
        my %ids;
        my %scenes;
        $scenes_list->foreach(
            sub {
                my ($orig_scene) = @_;

                my $scene = $orig_scene->cloneNode(1);
                my $scene_bn =
                    "scene-" . sprintf( "%.4d", ( $idx + 1 ) ) . ".xhtml";

                my $scene_xpc = _get_xpc($scene);
                $scene_xpc->findnodes(q{descendant::*/@id})->foreach(
                    sub {
                        my ($id) = @_;
                        $ids{ $id->nodeValue() } = $scene_bn;
                        return;
                    },
                );
                foreach my $h_idx ( 2 .. 6 )
                {
                    foreach my $h_tag (
                        $scene_xpc->findnodes(qq{descendant::xhtml:h$h_idx}) )
                    {
                        my $copy = $h_tag->cloneNode(1);
                        $copy->setNodeName( 'h' . ( $h_idx - 1 ) );

                        my $parent = $h_tag->parentNode;
                        $parent->replaceChild( $copy, $h_tag );
                    }
                }
                $scenes{$scene_bn} = [ $scene, $scene_xpc ];
                push @scene_bns, $scene_bn;
                ++$idx;

                return;
            },
        );

        foreach my $scene_bn (@scene_bns)
        {
            my ( $scene, $scene_xpc ) = @{ $scenes{$scene_bn} };

            # Fix anchorlinks
            $scene_xpc->findnodes(q{descendant::*[starts-with(@href,'#')]})
                ->foreach(
                sub {
                    my ($elem) = @_;
                    my $link   = $elem->getAttribute("href");
                    my $id     = substr( $link, 1 );
                    my $doc    = $ids{$id};
                    if ( $doc ne $scene_bn )
                    {
                        $elem->setAttribute( "href", "$doc$link" );
                    }
                    return;
                },
                );

            my $title =
                $scene_xpc->findnodes('descendant::xhtml:h1')->[0]
                ->textContent();
            my $esc_title    = escape_html($title);
            my $scene_string = $scene->toString();
            my $xmlns =
                q# xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"#;
            $scene_string =~ s{(<\w+)\Q$xmlns\E( )}{$1$2}g;
            path( $target_dir . "/$scene_bn" )->spew_utf8(<<"EOF");
<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en-US">
<head>
<title>$esc_title</title>
<meta charset="utf-8"/>
<link rel="stylesheet" href="style.css" />
</head>
<body>
$scene_string
</body>
</html>
EOF
        }
    }
    if ( $self->should_minify() )
    {
        local $ENV{APPLY_TEXTS} = "1";
        App::Gezer->new()->run(
            {
                ARGV => [
                    qw#--mode=minify --minifier-conf=bin/html-min-cli-config-file.conf --texts-dir=lib/ads#,
                    "--source-dir=$target_dir",
                    "--dest-dir=$target_dir",
                    "--",
                    @scene_bns,
                ],
            },
        );

    }

    my $gfx = 'Green-d10-dice.png';
    $self->gfx($gfx);
    path("$target_dir/images")->mkpath;
    my $script_dir = $self->script_dir;
    my $full_gfx   = path("$script_dir/../graphics/$gfx");
    if ( -e $full_gfx )
    {
        # say("full_gfx=$full_gfx");
        my $dest_gfx = path("$target_dir/images/$gfx");

        # say("dest_gfx=$dest_gfx");
        $dest_gfx->parent()->mkpath();
        $full_gfx->copy($dest_gfx);
    }

    $images = +{ %$images, %{ $self->images() }, };
    foreach my $img_src ( keys(%$images) )
    {
        my $dest = "$target_dir/$images->{$img_src}";

        path($dest)->parent->mkpath;
        copy( "$script_dir/../graphics/$img_src", $dest );

    }

    foreach my $basename ('style.css')
    {
        path("$target_dir/$basename")->spew_utf8(<<'EOF');
body
{
    text-align: left;
    font-family: sans-serif;
    background-color: white;
    color: black;
}
EOF
    }

    return;
}

sub output_json
{
    my ( $self, $args ) = @_;

    my $data_tree = $args->{data};

    my $orig_dir = Path::Tiny->cwd->absolute;

    my $target_dir = $self->target_dir;

    my $epub_fn =
        $target_dir->child( path( $self->epub_basename )->basename() . ".epub" )
        ->absolute;

    my $json_filename = $self->json_filename;
    my $json_abs =
        $target_dir->child( path($json_filename)->basename )->absolute;

    my $emit_json_with_utf8 = sub {
        my $fh = shift;
        return $fh->spew_raw(@_);
    };
    $emit_json_with_utf8->(
        $json_abs,
        (
            $jsonner->encode(
                { %{ $self->common_json_data() }, %$data_tree, },
            ),
        )
    );

    {
        chdir($target_dir);

        _my_make_epub( $json_abs->stringify(), $epub_fn->stringify(), );

        chdir($orig_dir);
    }

    $epub_fn->copy( $self->out_fn );

    return;
}

1;
