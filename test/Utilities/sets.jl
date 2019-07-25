using SparseArrays

@testset "Constant" begin
    @test MOI.constant(MOI.EqualTo(3)) == 3
    @test MOI.constant(MOI.GreaterThan(6)) == 6
    @test MOI.constant(MOI.LessThan(2)) == 2
end

@testset "Shifts" begin
    @test MOIU.shift_constant(MOI.EqualTo(3), 1) == MOI.EqualTo(4)
    @test MOIU.shift_constant(MOI.GreaterThan(6), -1) == MOI.GreaterThan(5)
    @test MOIU.shift_constant(MOI.LessThan(2), 2) == MOI.LessThan(4)
    @test MOIU.shift_constant(MOI.Interval(-2, 3), 1) == MOI.Interval(-1, 4)
end

@testset "Dimension" begin
    @test MOI.dimension(MOI.EqualTo(3.0)) === 1
    @test MOI.dimension(MOI.Reals(8)) === 8
    @test MOI.dimension(MOI.DualExponentialCone()) === 3
    @test MOI.dimension(MOI.PositiveSemidefiniteConeTriangle(4)) === 10
    @test MOI.dimension(MOI.PositiveSemidefiniteConeSquare(5)) === 25
    @test MOI.dimension(MOI.RootDetConeTriangle(6)) === 22
    @test MOI.dimension(MOI.LogDetConeTriangle(6)) === 23
    @test MOI.dimension(MOI.RootDetConeSquare(4)) === 17
    @test MOI.dimension(MOI.LogDetConeSquare(4)) === 18
    @test MOI.dimension(MOI.SOS2(collect(1:6))) === 6
end

@testset "Set dot" begin
    vec = zeros(6)
    @test MOIU.set_dot(vec, vec, MOI.SecondOrderCone(6)) == 0
    @test MOIU.set_dot(vec, vec, MOI.PositiveSemidefiniteConeTriangle(3)) == 0
    @test MOIU.set_dot(vec, vec, MOI.PositiveSemidefiniteConeSquare(3)) == 0
    vec[5] = 1
    @test MOIU.set_dot(vec, vec, MOI.SecondOrderCone(6)) == 1
    @test MOIU.set_dot(vec, vec, MOI.PositiveSemidefiniteConeTriangle(3)) == 2
    @test MOIU.set_dot(vec, vec, MOI.PositiveSemidefiniteConeSquare(3)) == 1
    vec[5] = 0
    vec[3] = 1
    @test MOIU.set_dot(vec, vec, MOI.SecondOrderCone(6)) == 1
    @test MOIU.set_dot(vec, vec, MOI.PositiveSemidefiniteConeTriangle(3)) == 1
    @test MOIU.set_dot(vec, vec, MOI.PositiveSemidefiniteConeSquare(3)) == 1

    vec = zeros(7)
    @test MOIU.set_dot(vec, vec, MOI.RootDetConeTriangle(3)) == 0
    vec[5] = 1
    @test MOIU.set_dot(vec, vec, MOI.RootDetConeTriangle(3)) == 2
    vec = zeros(8)
    @test MOIU. set_dot(vec, vec, MOI.LogDetConeTriangle(3)) == 0
    vec[5] = 1
    @test MOIU.set_dot(vec, vec, MOI.LogDetConeTriangle(3)) == 1
    
    sp_vec = spzeros(6)
    @test MOIU.set_dot(sp_vec, sp_vec, MOI.SecondOrderCone(6)) == 0
    @test MOIU.set_dot(sp_vec, sp_vec, MOI.PositiveSemidefiniteConeTriangle(3)) == 0
    @test MOIU.set_dot(sp_vec, sp_vec, MOI.PositiveSemidefiniteConeSquare(3)) == 0
    sp_vec[5] = 1
    @test MOIU.set_dot(sp_vec, sp_vec, MOI.SecondOrderCone(6)) == 1
    @test MOIU.set_dot(sp_vec, sp_vec, MOI.PositiveSemidefiniteConeTriangle(3)) == 2
    @test MOIU.set_dot(sp_vec, sp_vec, MOI.PositiveSemidefiniteConeSquare(3)) == 1
    sp_vec[5] = 0
    sp_vec[3] = 1
    @test MOIU.set_dot(sp_vec, sp_vec, MOI.SecondOrderCone(6)) == 1
    @test MOIU.set_dot(sp_vec, sp_vec, MOI.PositiveSemidefiniteConeTriangle(3)) == 1
    @test MOIU.set_dot(sp_vec, sp_vec, MOI.PositiveSemidefiniteConeSquare(3)) == 1

    sp_vec = spzeros(7)
    @test MOIU.set_dot(sp_vec, sp_vec, MOI.RootDetConeTriangle(3)) == 0
    sp_vec[5] = 1
    @test MOIU.set_dot(sp_vec, sp_vec, MOI.RootDetConeTriangle(3)) == 2
    sp_vec = spzeros(8)
    @test MOIU. set_dot(sp_vec, sp_vec, MOI.LogDetConeTriangle(3)) == 0
    sp_vec[5] = 1
    @test MOIU.set_dot(sp_vec, sp_vec, MOI.LogDetConeTriangle(3)) == 1
end

@testset "dot coefficients" begin
    vec = zeros(6)
    @test MOIU.dot_coefficients(vec, MOI.SecondOrderCone(6)) == vec
    @test MOIU.dot_coefficients(vec, MOI.PositiveSemidefiniteConeTriangle(3)) == vec
    vec[5] = 1
    @test MOIU.dot_coefficients(vec, MOI.SecondOrderCone(6)) == vec
    @test MOIU.dot_coefficients(vec, MOI.PositiveSemidefiniteConeTriangle(3)) == vec./2
    vec[5] = 0
    vec[3] = 1
    @test MOIU.dot_coefficients(vec, MOI.SecondOrderCone(6)) == vec
    @test MOIU.dot_coefficients(vec, MOI.PositiveSemidefiniteConeTriangle(3)) == vec

    vec = zeros(7)
    @test MOIU.dot_coefficients(vec, MOI.RootDetConeTriangle(3)) == vec
    vec[5] = 1
    @test MOIU.dot_coefficients(vec, MOI.RootDetConeTriangle(3)) == vec./2
    vec = zeros(8)
    @test MOIU. dot_coefficients(vec, MOI.LogDetConeTriangle(3)) == vec
    vec[5] = 1
    @test MOIU.dot_coefficients(vec, MOI.LogDetConeTriangle(3)) == vec

    sp_vec = spzeros(6)
    @test MOIU.dot_coefficients(sp_vec, MOI.SecondOrderCone(6)) == sp_vec
    @test MOIU.dot_coefficients(sp_vec, MOI.PositiveSemidefiniteConeTriangle(3)) == sp_vec
    sp_vec[5] = 1
    @test MOIU.dot_coefficients(sp_vec, MOI.SecondOrderCone(6)) == sp_vec
    @test MOIU.dot_coefficients(sp_vec, MOI.PositiveSemidefiniteConeTriangle(3)) == sp_vec./2
    sp_vec[5] = 0
    sp_vec[3] = 1
    @test MOIU.dot_coefficients(sp_vec, MOI.SecondOrderCone(6)) == sp_vec
    @test MOIU.dot_coefficients(sp_vec, MOI.PositiveSemidefiniteConeTriangle(3)) == sp_vec

    sp_vec = spzeros(7)
    @test MOIU.dot_coefficients(sp_vec, MOI.RootDetConeTriangle(3)) == sp_vec
    sp_vec[5] = 1
    @test MOIU.dot_coefficients(sp_vec, MOI.RootDetConeTriangle(3)) == sp_vec./2
    sp_vec = spzeros(8)
    @test MOIU. dot_coefficients(sp_vec, MOI.LogDetConeTriangle(3)) == sp_vec
    sp_vec[5] = 1
    @test MOIU.dot_coefficients(sp_vec, MOI.LogDetConeTriangle(3)) == sp_vec
end