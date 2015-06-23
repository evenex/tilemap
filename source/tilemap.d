// TODO ensure the unittest can run
private {// imports
	import autodata;
	import evx.meta;
	import evx.interval;
	import evx.infinity;
	import std.functional;
	import std.math;
	import std.traits : EnumMembers;
	import std.random : uniform;
}
public {// tilemap
	alias not = evx.meta.not;

	alias fvec = Vector!(2, float);
	alias ivec = Vector!(2, int);

	struct TileMap (Store) // REVIEW do we eventually want to turn this into a spatial wrapper over rcorre's tilemap? it would enable loading from xml, and this thing is already nothing but a thin wrapper over an array
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

	version (none) {
		auto cube_query (alias condition =_=> true, S,T, uint n)(ref S space, Vector!(n,T) pos, T width)
		{
			return aabb_query!condition (space, pos, Repeat!(n, width));
		}
		auto aabb_query (alias condition =_=> true, S,T, uint n, W...)(ref S space, Vector!(n,T) pos, W widths)
		if (dimensionality!S == n && W.length == n)
		{
			auto dims = vector (width, height)/2;

			ivec max = (pos + dims).clamp_to (space).fmap!(to!T) + 1, // REVIEW redundant fmap
				min = (pos - dims).clamp_to (space).fmap!(to!T);

			return space[min.x..max.x, min.y..max.y].lexi.filter!condition;
		}
		auto sphere_query (alias condition =_=> true, S,T, uint n)(S space, Vector!(n,T) pos, T radius)
		if (dimensionality!S == n)
		{
			auto intersects (fvec v)
			{
				return (pos 
					- zip(pos[], v[])
						.map!((p,q) => p.clamp (interval (q, q+T(1))))
						.Vector!(n,T)
				).fmap!(a => a^^2)[].sum 
					<= radius^^2
					;
			}

			return space[].neighborhood (pos, radius) 
				.lexi.filter!((coord,_) => intersects (coord))
				.map!((_,item) => item)
				.filter!condition;
		}
		Maybe!(ElementType!T) point_query (alias condition =_=> true, S,T, uint n)(S space, Vector!(n,T) pos)
		{
			if (pos in space[].orthotope)
				return typeof(return)(space[pos.tuple.expand]);
			else 
				return typeof(return)(null);
		}

		auto box_query (alias condition =_=> true, S,T, uint n)(ref S space, Vector!(n,T) pos, T width)
		{
			return box_query!condition (space, pos, width, width);
		}
		auto box_query (alias condition =_=> true, S,T, uint n)(ref S space, Vector!(n,T) pos, T width, T height)
		{
			return aabb_query!condition (space, pos, width, height);
		}
		auto circle_query (alias condition =_=> true, T)(ref TileMap!T tiles, fvec pos, float radius)
		{
			return sphere_query!condition (tiles, pos, radius);
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
				empty = not!f;
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

	auto neighborhood (alias boundary_condition = _ => ElementType!S.init, S, T, uint n)(S space, Vector!(n,T) origin, T radius)
	{
		alias r = radius;

		auto diameter = interval (-r, r+T(1));

		alias infinite = Repeat!(n, interval (-infinity!T, infinity!T));
		alias stencil = Repeat!(n, diameter);

		static index_into (R)(Vector!(n,T) index, R outer_space)
		{
			return outer_space[index.tuple.expand];
		}

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

	struct Only (T, uint n)
	{
		T[n] data;
		Interval!size_t slice;

		auto front ()
		{
			return data[slice.left];
		}
		auto popFront ()
		{
			++slice.left;
		}
		auto back ()
		{
			return data[slice.right-1];
		}
		auto popBack ()
		{
			--slice.right;
		}
		auto empty ()
		{
			return slice.width == 0;
		}

		auto access (size_t i)
		{
			return data[i];
		}
		auto length () const
		{
			return slice.width;
		}

		mixin AdaptorOps!(access, length, RangeExt);
	}
	auto only (Args...)(Args args)
	{
		enum n = Args.length;

		return Only!(CommonType!Args, n)([args], interval (0, n));
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
	alias GRAVITY = Cons!(0, 0.25);

	enum ubyte MAX_FPS = 60;
	enum ubyte TICKS_PER_FRAME = 1000 / MAX_FPS;

	struct Player
	{
		void roll (int direction)
		{
			move (direction.sgn * speed, 0);
			rotate (direction.sgn * speed/radius * 180f/PI);
		}

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
			spritesheet.setPosition ((pos * TILE_SIZE).tuple.expand);

			return this;
		}

		ref Player rotation_center (fvec v)
		{
			spritesheet.setRotationCenter(v.x, v.y);

			return this;
		}

		Spritesheet spritesheet;

		auto heat = 0f;

		enum float speed = 0.1;
		enum float radius = 0.5;
	}
	struct Tile 
	{
		Sprite sprite;
		fvec pos;

		enum Mask : ubyte {
			Air =		0,
			Ground = 	1<<0,
			Edge = 		1<<1,
			Grass = 	1<<2,
			Snow = 		1<<3,
			Ice = 		1<<4,
			Lava = 		1<<5,
			Spikes = 	1<<6,
			Brittle = 	1<<7,
		}

		Mask mask;
	}
	float melt_rate (ref Tile tile)
	{
		float[ubyte] melt_rates = [ // REVIEW make sure this doesn't allocate on each invocation, else we will move it back out or turn it into a dense CT Cons
			Tile.Mask.Lava: ubyte.max, // instant REVIEW ubyte?
			Tile.Mask.Grass: 10,
			Tile.Mask.Snow: -10,
			Tile.Mask.Ice: -25,
		];

		float rate (size_t i)()
		{
			if (auto rate = (tile.mask & 2^^i) in melt_rates)
				return *rate;
			else return 0;
		}

		return Map!(rate, Ordinal!(EnumMembers!(Tile.Mask))).sum;
	}

	void main () 
	{
		Window wnd = Window(MAP_WIDTH * TILE_SIZE, MAP_HEIGHT * TILE_SIZE, "Dgame Test");

		enum path = `./img/`;

		Texture player_tex = Texture(Surface((path)~"snowball.png"));

		Texture[] tile_textures = [
			Texture(Surface((path)~"Tile2.png")),
			Texture(Surface((path)~"Tile3.png")),
			Texture(Surface((path)~"Tile5.png")),
		];

		fvec start_pos, target_pos;

		// a = start, t = (walkable) tile, b = brittle tile, z = target
		// REVIEW how to abstract out the level?
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
						return Tile (new Sprite(tile_textures[uniform (0, tile_textures.length)], Vector2f (dims.tuple.expand)), pos, Tile.Mask.Grass);
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
				vector (player.pos.x.round, player.pos.y + 1)
					.fmap!(to!int)
					.clamp_to (tiles)
					.tuple.expand
			].mask == Tile.Mask.Air?
				true : false
				;
		}
		
		// REVIEW how to abstract out fps meter into debug widget
		Font fnt = Font("./font/arial.ttf", 12);
		Text fps = new Text(fnt);
		fps.setPosition(MAP_WIDTH * TILE_SIZE - 96, 4);

		bool running = true;

		auto keys_pressed (R)(R keys)
		{
			return keys.map!(Keyboard.isPressed);
		}

		void delegate()[Keyboard.Key] key_bindings = [
			Keyboard.Key.Esc: () {
				wnd.push(Event.Type.Quit);
			}
		];

		void delegate(ref Event)[Event.Type] event_responses = [
			Event.Type.Quit: (ref Event event) {
				running = false;
			},
			Event.Type.KeyDown: (ref Event event) {
				if (auto action = event.keyboard.key in key_bindings)
					(*action)();
			}
		];

		void update_game_state ()
		{
			enum dt = 1f/MAX_FPS;

			if (all (zip (player.pos[], target_pos[]).map!approxEqual))
			{
				writeln (`You've won!`);
				wnd.push(Event.Type.Quit);
			}
			else if (player.pos !in tiles[].orthotope)
			{
				writeln (`You've lost!`);
				wnd.push(Event.Type.Quit);
			}

			player.heat += tiles[].neighborhood (
				player.pos.fmap!(to!int), 1
			)
				.map!melt_rate.lexi.sum // REVIEW sum is associative, should it require explicit lexicographic traversal?
				* dt
			;

			if (player_in_air)
				player.move (GRAVITY);
		}
		void respond_to_events ()
		{
			static Event event;

			while (wnd.poll(&event))
				if (auto response_to = event.type in event_responses)
					(*response_to)(event);

			with (Keyboard.Key)
				keys_pressed (only (Left, Right))
					.zip (only (-1, 1))
					.filter!((pressed,_) => pressed)
					.map!((_,dir) => dir)
					.each!(dir => player.roll (dir))
					.each!(dir => player.spritesheet.selectFrame ((-dir + 1).to!ubyte/2)) // TODO each tuple expand
					;
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
			writeln (`heat: `, player.heat);
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
