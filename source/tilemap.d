// TODO ensure the unittest can run
private {// imports
    import autodata;
    import evx.meta;
    import evx.interval;
    import evx.infinity;
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
}
public {// dgame demo
    import std.stdio;
    import std.format;

    import Dgame.Window;
    import Dgame.Graphic;
    import Dgame.Math;
    import Dgame.System;

    enum ubyte MAP_WIDTH = 12;
    enum ubyte MAP_HEIGHT = 10;

    enum ubyte TILE_SIZE = 32;
    alias GRAVITY = Cons!(0, 0.2);

    enum ubyte MAX_FPS = 60;
    enum ubyte TICKS_PER_FRAME = 1000 / MAX_FPS;

    auto keys_pressed (R)(R keys)
    {
        return keys.map!(Keyboard.isPressed);
    }

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

        enum float speed = 0.12;
        enum float radius = 0.5;
    }
    struct Tile 
    {
        Sprite sprite;
        fvec pos;

        enum Mask : ubyte {
            Air =       0,
            Ground =    1<<0,
            Edge =      1<<1,
            Grass =     1<<2,
            Snow =      1<<3,
            Ice =       1<<4,
            Lava =      1<<5,
            Spikes =    1<<6,
            Brittle =   1<<7,
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

        Texture[3] tile_textures = [
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
            .laminate (MAP_WIDTH, MAP_HEIGHT)
            .index_zip
            .map!(fprod!(fvec, identity))
            .map!((fvec pos, char c)
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

        bool player_in_air () // BUG need better collision detection... factor in velocity?
        {
            return player.pos.y.not!approxEqual (player.pos.y.floor)
                || tiles[].neighborhood (
                    vector (player.pos.x.round, player.pos.y)
                        .fmap!(to!int), 1
                )[0,1].mask == Tile.Mask.Air?
                    true : false
                    ;
        }
        
        Font font = Font("./font/arial.ttf", 12);

        struct TextWidget
        {
            Text text;

            string delegate() data;

            this (ref Font font, string delegate() data)
            {
                this.text = new Text(font);
                this.data = data;
            }
            ref pos (fvec pos)
            {
                text.setPosition (pos.tuple.expand);

                return this;
            }

            ref update ()
            {
                text.format (data ());

                return text;
            }
            alias update this;
        }

        TextWidget[] widgets = [
            TextWidget (font, (){static StopWatch sw_fps; return format ("FPS: %d", sw_fps.getCurrentFPS());})
                .pos (fvec (MAP_WIDTH * TILE_SIZE - 126, 2)),
            TextWidget (font, () => format ("POS: (%.1f, %.1f)", player.pos.tuple.expand))
                .pos (fvec (MAP_WIDTH * TILE_SIZE - 126, 16)),
            TextWidget (font, () => format ("y: [%.1f, %d]", player.pos.y.round, (player.pos.y+1).to!int))
                .pos (fvec (MAP_WIDTH * TILE_SIZE - 56, 2)), 
        ];

        bool running = true;

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

        void update_game_state () // BUG if snowball runs into ground tile while falling, he will stay halfway through the tile and be grounded - he should keep falling
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
        }
        void react_to_keyboard ()
        {
            with (Keyboard.Key)
                zip (
                    only (Left, Right).keys_pressed,
                    only (-1, 1)
                )
                    .filter!((pressed,_) => pressed)
                    .each!((_,dir) => (
                        player.roll (dir),
                        player.spritesheet.selectFrame ((-dir + 1).to!ubyte/2))
                    );
        }
        void draw ()
        {
            wnd.clear();

            foreach (ref widget; widgets)
                wnd.draw (widget);

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
            1? react_to_keyboard : {}, // REVIEW keyboard reaction no longer restricted to player on ground - not like original demo, but feels better. i vote to keep this
            1? draw              : {},
            0? log               : {},
            running
        )).each!(Thread.sleep);
    }
}
