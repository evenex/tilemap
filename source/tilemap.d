// TODO ensure the unittest can run
private {// imports
	import autodata;
	import evx.meta;
	import evx.interval;
	import evx.infinity;
	import std.functional;
	import std.math;
}
public {// tilemap
	alias not = evx.meta.not;

	alias fvec = Vector!(2, float);
	alias ivec = Vector!(2, int);

	struct TileMap (Store)
	if (dimensionality!Store == 2)
	{
		Store data;

		auto limit (uint i)() const // TODO need to be able to choose between defining length or limit, let the other be resolved to global, but avoid mutual recursion
		// REVIEW most spaces will have (0,size_t) limits, might as well let them define multidimensional length -- however retrofitting autodata with this could be a huge pain in the ass
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

	auto box_query (alias condition =_=> true, T)(ref TileMap!T tiles, fvec pos, float width)
	{
		return box_query!condition (tiles, pos, width, width);
	}
	auto box_query (alias condition =_=> true, T)(ref TileMap!T tiles, fvec pos, float width, float height)
	{
		auto dims = vector (width, height)/2;

		ivec max = (pos + dims).clamp_to (tiles) + 1,
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

		return tiles.neighborhood (pos, radius) // REVIEW
			.lexi.filter!((coord,_) => intersects (coord))
			.map!((_,tile) => tile)
			.filter!condition;
	}
	Maybe!(ElementType!T) point_query (T)(ref TileMap!T tiles, fvec pos)
	{
		auto ipos = pos.fmap!(to!int);

		if (ipos in tiles[].orthotope)
			return typeof(return)(tiles[ipos.x, ipos.y]);
		else
			return typeof(return)(null);
	}

	unittest
	{
		TileMap!(Array!(int, 2)) testiles;

		/*
			we test with a 4x4 grid of unique integers
		*/
		testiles.data = [0,1,2,3].by ([0,1,2,3]).map!((a,b) => a + 4*b);

		/*
			for box query we use side length, for circles we use radius
		*/
		auto a = 1.8;
		assert (testiles.box_query (0.fvec, a, a) == [0]);
		assert (testiles.circle_query (0.fvec, a/2) == [0]);

		auto b = 1.59999;
		assert (testiles.box_query (1.2.fvec, b, b) == [0,1,4,5]);
		assert (testiles.circle_query (1.2.fvec, b/2) == [0,1,4,5]);

		/* if the circle is set just right, it will intersect 3 tiles (where an equivalent box query would give 4)
		*/
		auto c = 2.0;
		assert (testiles.box_query (0.0.fvec, c, c) == [0,1,4,5]);
		assert (testiles.circle_query (0.0.fvec, c/2) == [0,1,4]);
	}
}
public {// to library
	import core.time;
	import core.thread;

	struct Throttle (alias f)
	{
		uint ticks_per_frame;

		StopWatch stopwatch;
		bool empty;

		auto remaining_ticks_in_frame ()
		{
			auto remaining = ticks_per_frame - stopwatch.getElapsedTicks();

			if (remaining < ticks_per_frame)
			 	return remaining.msecs;
			else
				return 0.msecs;
		}

		alias front = remaining_ticks_in_frame;
		void popFront ()
		{
			if (stopwatch.getElapsedTicks() > ticks_per_frame)
			{
				stopwatch.reset();
				empty = not (f());
			}
		}
	}
	auto throttle (alias f)(uint ticks_per_frame)
	{
		return Throttle!f (ticks_per_frame);
	}

	auto ref each (alias f, R)(auto ref R range)
	{
		foreach (ref item; range)
			cast(void) f (item);

		return range;
	}

	private auto clamp_to (V,S)(V v, ref S space)
	{
		auto clamp_axis (uint i)()
			{return v[i].clamp (space.limit!i - interval(0,1));}

		return V(Map!(clamp_axis, Iota!(dimensionality!S)));
	}

	auto neighborhood (alias boundary_condition = _ => ElementType!S.init, S, T, uint n)(S space, Vector!(n,T) origin, T radius) // REVIEW this arg for a boundary condition... kinda awkward
	{
		alias r = radius;

		auto diameter = interval (-r, r+T(1));

		static index_into (R)(Vector!(n,T) index, R outer_space)
		{
			return outer_space[index.tuple.expand];
		}

		alias infinite = Repeat!(n, interval (-infinity!T, infinity!T));
		alias stencil = Repeat!(n, diameter);

		return stencil.orthotope
			.map!(typeof(origin))
			.map!sum (origin)
			.map!index_into (
				space.embedded_in (
					infinite.orthotope
						.map!boundary_condition 
				)
			);
	}
}
public {// dgame demo
	import std.stdio;

	import Dgame.Window;
	import Dgame.Graphic;
	import Dgame.Math;
	import Dgame.System;

	enum ubyte MAP_WIDTH = 12;
	enum ubyte MAP_HEIGHT = 10;

	enum ubyte TILE_SIZE = 32;
	enum ubyte ROTATION = 90;
	alias GRAVITY = Cons!(0, 0.25);

	enum ubyte MAX_FPS = 60;
	enum ubyte TICKS_PER_FRAME = 1000 / MAX_FPS;

	struct Tile 
	{
		Sprite sprite;
		fvec pos;

		enum Mask : ubyte {
			Air =		0,
			Ground = 	2^^0,
			Edge = 		2^^1,
			Grass = 	2^^2,
			Snow = 		2^^3,
			Ice = 		2^^4,
			Lava = 		2^^5,
			Spikes = 	2^^6,
			Brittle = 	2^^7,
		}

		Mask mask;
	}
	float melt_rate (ref Tile tile)
	{
		float[size_t] melt_rates = [ // REVIEW make sure this doesn't allocate on each invocation, else we will move it back out or turn it into a dense CT Cons
			Tile.Mask.Lava: ubyte.max, // instant
			Tile.Mask.Grass: 10,
			Tile.Mask.Snow: -10,
			Tile.Mask.Ice: -25,
		];

		float rate (size_t i)
		{
			if (auto rate = (tile.mask & 2^^i) in melt_rates)
				return *rate;
			else return 0;
		}

		return Nat[0..(Cons!(__traits(allMembers, Tile.Mask)).length)].map!rate.sum;
	}

	struct Player
	{
		void move (float x, float y)
		{
			pos = fvec(pos.x + x, pos.y + y);
		}

		void rotate (float rad)
		{
			spritesheet.rotate (rad);
		}
		auto rotation ()
		{
			return spritesheet.getRotation();
		}

		fvec pos ()
		{
			return spritesheet.getPosition().tupleof.fvec/TILE_SIZE;
		}
		ref Player pos (fvec pos)
		{
			spritesheet.setPosition (Vector2f((pos * TILE_SIZE).tuple.expand));

			return this;
		}

		ref Player rotation_center (fvec v)
		{
			spritesheet.setRotationCenter(v.x, v.y);

			return this;
		}

		Spritesheet spritesheet;
	}

	void main () 
	{
		Window wnd = Window(MAP_WIDTH * TILE_SIZE, MAP_HEIGHT * TILE_SIZE, "Dgame Test");

		enum path = `/home/vlad/github/Dgame-Tutorial/`;

		Texture player_tex = Texture(Surface((path)~"Basti-Box.png"));
		Texture tile_tex = Texture(Surface((path)~"Tile.png"));

		fvec start_pos, target_pos;

		// 0 = empty, a = start, t = (walkable) tile, b = brittle tile, z = target
		auto tiles = tilemap (
			` a          `
			` ttttt  ttt `
			`   tttt     `
			`            `
			`tt    tttt t`
			`     ttt  tt`
			`            `
			` tttt       `
			`           z`
			`   ttttttttt`
			.laminate (MAP_WIDTH, MAP_HEIGHT) // REVIEW alternatively, stitch 1D array of rows into 2D array of elements (string[] -> Array!(2, char))
			.zip (map!fvec (Nat[0..MAP_WIDTH].by (Nat[0..MAP_HEIGHT]))) // REVIEW alternatively, zipwith indices, map fprod(identity, fvec)
			.map!((char c, fvec pos)
				{// assign tile
					auto dims () {return pos * TILE_SIZE;}

					// REVIEW telescoping ctors
					if (c == 't')
						return Tile (new Sprite(tile_tex, Vector2f (dims.tuple.expand)), pos, Tile.Mask.Ground);
					else if (c == 'a')
						return Tile (null, start_pos = pos);
					else if (c == 'z')
						return Tile (null, target_pos = pos);
					else 
						return Tile (null, pos); 
				}
			)
			.array
		);

		auto player = Player (new Spritesheet(player_tex, Rect(0, 0, 32, 32)))
			.pos (start_pos)
			.rotation_center (16.fvec)
			;
		bool player_in_air ()
		{
			return tiles[
				(player.pos + fvec(0,1))
					.fmap!(to!int)
					.clamp_to (tiles)
					.tuple.expand
			].mask == Tile.Mask.Air?
				true : false
				;
		}
		
		Font fnt = Font((path)~"samples/font/arial.ttf", 12);
		Text fps = new Text(fnt);
		fps.setPosition(MAP_WIDTH * TILE_SIZE - 96, 4);

		bool running = true;

		void delegate()[Keyboard.Key] key_bindings = [
			Keyboard.Key.Left: () {
				if (not!player_in_air)
				{
					player.move(-1, 0);
					player.rotate(ROTATION * -1);
					player.spritesheet.selectFrame(0);
				}
			},
			Keyboard.Key.Right: () {
				if (not!player_in_air)
				{
					player.move(1, 0);
					player.rotate(ROTATION);
					player.spritesheet.selectFrame(1);
				}
			},
			Keyboard.Key.Esc: () {
				wnd.push(Event.Type.Quit);
			}
		];

		void delegate(ref Event)[Event.Type] event_responses = [
			Event.Type.Quit: (ref Event event) {
				running = false;
			},
			Event.Type.KeyDown: (ref Event event) {
				if (auto movement = event.keyboard.key in key_bindings)
					(*movement)();
			}
		];

		void update_game_state ()
		{
			if (player.pos == target_pos)
			{
				writeln (`You've won!`);
				wnd.push(Event.Type.Quit);
			}
			else if (player.pos !in tiles[].orthotope)
			{
				writeln (`You've lost!`);
				wnd.push(Event.Type.Quit);
			}

			if (player_in_air)
				player.move (GRAVITY);
		}
		void respond_to_events ()
		{
			static Event event;

			while (wnd.poll(&event))
				if (auto response_to = event.type in event_responses)
					(*response_to)(event);
		}
		void update_fps_meter () // allocates (string appender)
		{
			static StopWatch sw_fps;

			fps.format("FPS: %d", sw_fps.getCurrentFPS());
		}
		void draw ()
		{
			wnd.clear();

			wnd.draw(fps);

			tiles[].lexi.filter!(tile => tile.sprite !is null)
				.each!(tile => wnd.draw (tile.sprite));

			wnd.draw(player.spritesheet);

			wnd.display();
		}
		void log () // allocates (writeln)
		{
			tiles[].neighborhood!((i,j) => Tile (null, fvec(i,j)))
				(player.pos.fmap!(to!int), 1)
				.lexi.writeln;
		}

		TICKS_PER_FRAME.throttle!(() => (
			1? update_game_state : {},
			1? respond_to_events : {},
			1? update_fps_meter  : {},
			1? draw              : {},
			0? log               : {},
			running
		)).each!(Thread.sleep);
	}
}
