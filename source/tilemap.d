private {
	import autodata;
	import evx.interval;
	import std.functional;
	import std.math;
}

version = b;

auto ref each (alias f, R)(auto ref R range)
{
	foreach (ref item; range)
		f (item);
}

alias fvec = Vector!(2, float);
alias ivec = Vector!(2, int);

struct TileMap (Store)
if (dimensionality!Store == 2)
{
	Store data;

	auto limit (uint i)() const
	{
		return data.limit!i.fmap!(to!int);
	}

	ref access (int x, int y)
	{
		return data[size_t(x), size_t(y)];
	}

	auto width () const {return this.limit!0.width;}
	auto height () const {return this.limit!1.width;}

	auto pull (S)(S space, Interval!int xs, Interval!int ys)
	{
		foreach (i, ref a; data[xs,ys].lexi)
			a = space.lexi[i];
	}
	auto pull (S,T...)(S space, T dims)
	if (Any!(is_interval, T) && not (All!(is_interval, T)))
	{
		import std.typecons : reverse;

		auto dim_range (uint i) {return tuple (dims[i].repeat (dims[(i+1)%2].width), dims[(i+1)%2]);}

		static if (is_interval!(T[0]))
			auto coords = dim_range!0.expand.zip;
		else 
			auto coords = dim_range!1.reverse.expand.zip;

		foreach (i, coord; dim_range)
			data[coord.expand] = space[i];
	}

	mixin TransferOps!(pull, SliceOps, access, width, height, RangeExt);
}
auto tilemap (S)(S space)
{
	return TileMap!S (space);
}

private auto clamp_to (T)(fvec v, ref TileMap!T tiles)
{
	return vector (
		v.x.clamp (interval (0, tiles.width)),
		v.y.clamp (interval (0, tiles.height))
	).fmap!(to!int);
}

auto neighborhood (T)(ref TileMap!T tiles, fvec pos, float radius)
{
	ivec max = (pos + radius + 1).clamp_to (tiles),
		min = (pos - radius).clamp_to (tiles);

	return map!fvec (orthotope (tiles.limit!0, tiles.limit!1))
		.zip (tiles[])[min.x..max.x, min.y..max.y];
}

auto box_query (alias condition =_=> true, T)(ref TileMap!T tiles, fvec pos, float width)
{
	return box_query!condition (tiles, pos, width, width);
}
auto box_query (alias condition =_=> true, T)(ref TileMap!T tiles, fvec pos, float width, float height)
{
	auto dims = vector (width, height)/2;

	ivec max = (pos + dims + 1).clamp_to (tiles),
		min = (pos - dims).clamp_to (tiles);

	return tiles[min.x..max.x, min.y..max.y].lexi.filter!condition;
}
auto circle_query (alias condition =_=> true, T)(ref TileMap!T tiles, fvec pos, float radius)
{
	auto intersects (fvec v)
	{
		return (pos - fvec (
				pos.x.clamp (interval (v.x, v.x + 1)),
				pos.y.clamp (interval (v.y, v.y + 1))
			))
			.fmap!(a => a^^2)[].sum <= radius^^2;
	}

	return tiles.neighborhood (pos, radius)
		.lexi.filter!((coord,_) => intersects (coord))
		.map!((_,tile) => tile)
		.filter!condition;
}
Maybe!(ElementType!T) point_query (T)(ref TileMap!T tiles, Vector2f pos)
{
	auto ipos = tuple (pos.x, pos.y).fvec.fmap!(to!int);

	if (
		ipos.x.is_contained_in (tiles[].limit!0) 
		&& ipos.y.is_contained_in (tiles[].limit!1)
	)

		return typeof(return)(tiles[ipos.x, ipos.y]);
	else
		return typeof(return)(null);
}

version (a)
void main ()
{
	TileMap!(Array!(int, 2)) testmap;

	/*
		we test with a 4x4 grid of unique integers
	*/
	testmap.data = [0,1,2,3].by ([0,1,2,3]).map!((a,b) => a + 4*b);

	/*
		for box query we use side length, for circles we use radius
	*/
	auto a = 1.8;
	assert (testmap.box_query (0.fvec, a, a) == [0]);
	assert (testmap.circle_query (0.fvec, a/2) == [0]);

	auto b = 1.59999;
	assert (testmap.box_query (1.2.fvec, b, b) == [0,1,4,5]);
	assert (testmap.circle_query (1.2.fvec, b/2) == [0,1,4,5]);

	/* if the circle is set just right, it will intersect 3 tiles (where an equivalent box query would give 4)
	*/
	auto c = 2.0;
	assert (testmap.box_query (0.0.fvec, c, c) == [0,1,4,5]);
	assert (testmap.circle_query (0.0.fvec, c/2) == [0,1,4]);
}

import std.stdio;
import std.array: cache = array;

import Dgame.Window;
import Dgame.Graphic;
import Dgame.Math;
import Dgame.System;

enum ubyte MAP_WIDTH = 12;
enum ubyte MAP_HEIGHT = 10;

enum ubyte TILE_SIZE = 32;
enum ubyte MOVE = TILE_SIZE;
enum ubyte ROTATION = 90;
enum ubyte GRAVITY = TILE_SIZE / 4;

enum ubyte MAX_FPS = 60;
enum ubyte TICKS_PER_FRAME = 1000 / MAX_FPS;

struct Tile
{
	Sprite sprite;
	Vector2f pos;

	bool is_start_tile; // REVIEW this sucks
	bool is_target_tile;
}
version (b)
void main() 
{
    Window wnd = Window(MAP_WIDTH * TILE_SIZE, MAP_HEIGHT * TILE_SIZE, "Dgame Test");

	enum path = `/home/vlad/github/Dgame-Tutorial/`;

    Texture player_tex = Texture(Surface((path)~"Basti-Box.png"));
    Texture tile_tex = Texture(Surface((path)~"Tile.png"));

    // 0 = empty, a = start, t = (walkable) tile, b = brittle tile, z = target
	Tile assign_tile (char c, Vector2f pos)
    {
		auto dims () {return pos * TILE_SIZE;}

        if (c == 't')
            return Tile (new Sprite(tile_tex, dims), pos);
        else if (c == 'a')
            return Tile (null, pos, true, false);
        else if (c == 'z')
			return Tile (null, pos, false, true);

		return Tile.init;
    }

	auto tmap = tilemap (
		[
			'0', 'a', '0', '0', '0', '0', '0', '0', '0', '0', '0', '0',
			'0', 't', 't', 't', 't', 't', '0', '0', 't', 't', 't', '0',
			'0', '0', '0', 't', 't', 't', 't', '0', '0', '0', '0', '0',
			'0', '0', '0', '0', '0', '0', '0', '0', '0', '0', '0', '0',
			't', 't', '0', '0', '0', '0', 't', 't', 't', 't', '0', 't',
			'0', '0', '0', '0', '0', 't', 't', 't', '0', '0', 't', 't',
			'0', '0', '0', '0', '0', '0', '0', '0', '0', '0', '0', '0',
			'0', 't', 't', 't', 't', '0', '0', '0', '0', '0', '0', '0',
			'0', '0', '0', '0', '0', '0', '0', '0', '0', '0', '0', 'z',
			'0', '0', '0', 't', 't', 't', 't', 't', 't', 't', 't', 't',
		]
		.laminate (MAP_WIDTH, MAP_HEIGHT)
		.zip (map!Vector2f (Nat[0..MAP_WIDTH].by (Nat[0..MAP_HEIGHT])))
		.map!assign_tile
		.array
	);

	struct Player
	{
		fvec pos ()
		{
			return spritesheet.getPosition().tupleof.fvec/MOVE;
		}
		void pos (Vector2f pos)
		{
			spritesheet.setPosition(pos*MOVE);
		}
		Spritesheet spritesheet;
		alias spritesheet this;
	}
 	auto player = Player (new Spritesheet(player_tex, Rect(0, 0, 32, 32)));
    
    player.pos = tmap[].lexi.filter!(t => t.is_start_tile).front.pos;
    player.setRotationCenter(16, 16);

    Font fnt = Font((path)~"samples/font/arial.ttf", 12);
    Text fps = new Text(fnt);
    Text pos_txt = new Text(fnt);
	fps.setPosition(MAP_WIDTH * TILE_SIZE - 96, 4);

    StopWatch sw;
    StopWatch sw_fps;

    bool running = true;

    Event event;
    while (running) {
        wnd.clear();

        fps.format("FPS: %d", sw_fps.getCurrentFPS());

        if (sw.getElapsedTicks() > TICKS_PER_FRAME) {
            sw.reset();

			auto ground_contact = tmap[player.pos.x.to!int, player.pos.y.to!int + 1].sprite !is null;

			auto center (T)(Interval!(T,T) ival)
			{
				return ival.left + ival.width/2f;
			}

			if (!ground_contact)
				player.move(0, GRAVITY);
            
            while (wnd.poll(&event)) {
                switch (event.type) {
                    case Event.Type.Quit:
                        writeln("Quit Event");
                        running = false;
                    break;
                        
                    case Event.Type.KeyDown:
                        writeln("Pressed key ", event.keyboard.key);
                        
                        if (event.keyboard.key == Keyboard.Key.Esc)
                            running = false;
                        else if (ground_contact) {
                            switch (event.keyboard.key) {
                                case Keyboard.Key.Left:
                                    player.move(MOVE * -1, 0);
                                    player.rotate(ROTATION * -1);
                                    writeln(player.getRotation());
                                    player.selectFrame(0);
                                break;
                                case Keyboard.Key.Right:
                                    player.move(MOVE, 0);
                                    player.rotate(ROTATION);
                                    writeln(player.getRotation());
                                    player.selectFrame(1);
                                break;
                                default: break;
                            }
                        }
                    break;
                        
                    default: break;
                }
            }

            if (tmap.point_query (player.getPosition()).fmap!(tile => tile.is_target_tile).to_list[0]) {
                wnd.push(Event.Type.Quit);
                writeln("You've won!");
            } else {
                const Vector2f pos = player.getPosition();
                if (pos.x > (MAP_WIDTH * TILE_SIZE) ||
                    pos.x < 0 ||
                    pos.y > (MAP_HEIGHT * TILE_SIZE) ||
                    pos.y < 0)
                {
                    writeln("You've lost!");
                    wnd.push(Event.Type.Quit);
                }
            }
        }

        wnd.draw(fps);
        wnd.draw(pos_txt);

        tmap[].lexi.filter!(tile => tile.sprite !is null).each!(tile => wnd.draw (tile.sprite));

        wnd.draw(player);

        wnd.display();
    }
}
