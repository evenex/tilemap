private {// imports
	import autodata;
	import evx.meta;
	import evx.interval;
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

	private auto clamp_to (T)(fvec v, ref TileMap!T tiles)
	{
		return vector (
			v.x.clamp (interval (0, tiles.width)),
			v.y.clamp (interval (0, tiles.height))
		).fmap!(to!int);
	}

	auto neighborhood (T)(ref TileMap!T tiles, ivec pos, int radius)
	{
		/*
			REVIEW
			rad == 1 => [
				[(-1,-1), (0,-1), (1,-1)],
				[(-1, 0), (0, 0), (1, 0)],
				[(-1, 1), (0, 1), (1, 1)],
			]

			rad == 2 => [
				[(-2,-2), (-1,-2), (0,-2), (1,-2), (2,-2)],
				[(-2,-1), (-1,-1), (0,-1), (1,-1), (2,-1)],
				[(-2, 0), (-1, 0), (0, 0), (1, 0), (2, 0)],
				[(-2, 1), (-1, 1), (0, 1), (1, 1), (2, 1)],
				[(-2, 2), (-1, 2), (0, 2), (1, 2), (2, 2)],
			]
		*/
		alias r = radius;

		ivec max = (pos + r + 1f).clamp_to (tiles),
			min = (pos - r + 0f).clamp_to (tiles);

		return ortho (interval (-r,r+1), interval (-r,r+1))
			.map!((x,y) => tuple (ivec(x,y), tiles[pos.x + x, pos.y + y]))
			;
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
	Maybe!(ElementType!T) point_query (T)(ref TileMap!T tiles, fvec pos)
	{
		auto ipos = pos.fmap!(to!int);

		if (
			ipos.x.is_contained_in (tiles[].limit!0)  // REVIEW vec in orthotope
			&& ipos.y.is_contained_in (tiles[].limit!1)
		)

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
	struct Throttle (alias f)
	{
		uint ticks_per_frame;

		StopWatch stopwatch;
		bool empty;

		alias front = not!empty;
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
}
public {// dgame demo
	import std.stdio;
	import std.array: cache = array;

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
		Vector2f pos;

		bool is_start_tile; // REVIEW this sucks
		bool is_target_tile;

		enum Mask : ubyte {
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

	void main () 
	{
		Window wnd = Window(MAP_WIDTH * TILE_SIZE, MAP_HEIGHT * TILE_SIZE, "Dgame Test");

		enum path = `/home/vlad/github/Dgame-Tutorial/`;

		Texture player_tex = Texture(Surface((path)~"Basti-Box.png"));
		Texture tile_tex = Texture(Surface((path)~"Tile.png"));

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
			.zip (map!Vector2f (Nat[0..MAP_WIDTH].by (Nat[0..MAP_HEIGHT]))) // REVIEW alternatively, zipwith indices, map fprod(identity, fvec)
			.map!((char c, Vector2f pos)
				{// assign tile
					auto dims () {return pos * TILE_SIZE;}

					if (c == 't')
						return Tile (new Sprite(tile_tex, dims), pos);
					else if (c == 'a')
						return Tile (null, pos, true, false);
					else if (c == 'z')
						return Tile (null, pos, false, true);
					else 
						return Tile (null, pos); 
				}
			)
			.array
		);

		struct Player
		{
			void move (float x, float y)
			{
				pos = Vector2f(pos.x + x, pos.y + y);
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
			ref Player pos (Vector2f pos)
			{
				spritesheet.setPosition (pos*TILE_SIZE);

				return this;
			}

			ref Player rotation_center (fvec v)
			{
				spritesheet.setRotationCenter(v.x, v.y);

				return this;
			}

			bool is_grounded ()
			{
				return not (
					pos.x.to!int.not!is_contained_in (tiles[].limit!0) // TODO vec contained in orthotope
					|| (pos.y.to!int + 1).not!is_contained_in (tiles[].limit!1)
					|| tiles[pos.x.to!int, pos.y.to!int + 1].sprite is null
				);
			}

			Spritesheet spritesheet;
		}

		auto player = Player (new Spritesheet(player_tex, Rect(0, 0, 32, 32)))
			.pos (tiles[].lexi.filter!(t => t.is_start_tile).front.pos)
			.rotation_center (16.fvec)
			;
		
		Font fnt = Font((path)~"samples/font/arial.ttf", 12);
		Text fps = new Text(fnt);
		fps.setPosition(MAP_WIDTH * TILE_SIZE - 96, 4);

		bool running = true;

		void delegate()[Keyboard.Key] key_bindings = [
			Keyboard.Key.Left: () {
				if (player.is_grounded)
				{
					player.move(-1, 0);
					player.rotate(ROTATION * -1);
					writeln(player.rotation);
					player.spritesheet.selectFrame(0);
				}
			},
			Keyboard.Key.Right: () {
				player.move(1, 0);
				player.rotate(ROTATION);
				writeln(player.rotation);
				player.spritesheet.selectFrame(1);
			},
			Keyboard.Key.Esc: () {
				wnd.push(Event.Type.Quit);
			}
		];

		void delegate(ref Event)[Event.Type] event_responses = [
			Event.Type.Quit: (ref Event event) {
				writeln("Quit Event");
				running = false;
			},
			Event.Type.KeyDown: (ref Event event) {
				writeln("Pressed key ", event.keyboard.key);
				
				if (auto movement = event.keyboard.key in key_bindings)
					(*movement)();
			}
		];

		void respond_to_events () 
		{
			static Event event;

			while (wnd.poll(&event))
				if (auto response_to = event.type in event_responses)
					(*response_to)(event);
		}
		void update_fps_meter ()
		{
			static StopWatch sw_fps;

			fps.format("FPS: %d", sw_fps.getCurrentFPS());
		}
		void update_game_state ()
		{
			if (tiles.point_query (player.pos).fmap!(tile => tile.is_target_tile).to_list[0]) {
				wnd.push(Event.Type.Quit);
				writeln("You've won!");
			}
			else if (player.pos.x.not!is_contained_in (tiles[].limit!0) // TODO vec contained in orthotope
				|| player.pos.y.not!is_contained_in (tiles[].limit!1)
			) {
				wnd.push(Event.Type.Quit);
				writeln("You've lost!");
			}

			if (not (player.is_grounded))
				player.move(GRAVITY);
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

		//TEMP
		version (none)
			tiles.neighborhood (player.pos.fmap!(to!int), 1).map!((a,b)=>b.melt_rate).lexi.writeln; // BUG neighborhood needs boundary conditions if we go out of bounds
		else tiles.neighborhood (ivec(5,5), 1).map!((a,b)=>b.melt_rate).lexi.writeln;

		TICKS_PER_FRAME.throttle!(() => (
			respond_to_events,
			update_fps_meter,
			update_game_state,
			draw,
			running
		)).each!(_=>_);
	}
}
