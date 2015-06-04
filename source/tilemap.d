private {
	import autodata;
	import evx.interval;
	import std.functional;
	import std.math;
}

alias fvec = Vector!(2, float);
alias uvec = Vector!(2, size_t);

struct TileMap (Store)
if (dimensionality!Store == 2)
{
	Store data;

	/*
		limit is an idiom from my interval library, it is like "length" but makes an interval instead
	*/
	auto limit (uint i)() const
	{
		return data.limit!i;
	}

	ref access (size_t x, size_t y)
	{
		return data[x,y];
	}

	auto width () const {return this.limit!0.width;}
	auto height () const {return this.limit!1.width;}

	mixin SliceOps!(access, width, height, RangeExt);
}

private auto clamp_to (T)(fvec v, ref TileMap!T tiles)
{
	return vector (
		v.x.clamp (interval (0, tiles.width)),
		v.y.clamp (interval (0, tiles.height))
	).fmap!(compose!(to!size_t, floor));
}

auto box_query (alias condition =_=> true, T)(ref TileMap!T tiles, fvec pos, float width, float height)
{
	auto dims = vector (width, height)/2;

	uvec max = (pos + dims + 1).clamp_to (tiles),
		min = (pos - dims).clamp_to (tiles);

	return tiles[min.x..max.x, min.y..max.y].lexi.filter!condition;
}
auto circle_query (alias condition =_=> true, T)(ref TileMap!T tiles, fvec pos, float radius)
{
	uvec max = (pos + radius + 1).clamp_to (tiles),
		min = (pos - radius).clamp_to (tiles);

	auto intersects (fvec v)
	{
		return (pos - fvec (
				pos.x.clamp (interval (v.x, v.x + 1)),
				pos.y.clamp (interval (v.y, v.y + 1))
			))
			.fmap!(a => a^^2)[].sum <= radius^^2;
	}

	return orthotope (tiles.limit!0, tiles.limit!1)
		.map!fvec.zip (tiles[])[min.x..max.x, min.y..max.y]
		.lexi.filter!((coord,_) => intersects (coord))
		.map!((_,tile) => tile)
		.filter!condition;
}

/*
	Randy, regarding the gc:
	you can't mark main @nogc because of std.conv.to and some nontemplate functions that haven't been marked @nogc
	but running infognition's gc allocation tracker tool inside of the query functions will verify that no allocations are being triggered
	too bad @nogc is still such a pain to use
	if @nogc could be inferred on non-template functions, this would be ideal.
	unfortunately, i can't template all of the functions i use because i sometimes need to get ParameterType and ReturnType for metaprogramming
*/
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
