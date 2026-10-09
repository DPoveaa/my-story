extends SceneTree

const TestM1Script = preload("res://tests/test_m1.gd")
const TestM1_1Script = preload("res://tests/test_m1_1.gd")
const TestM2Script = preload("res://tests/test_m2.gd")
const TestM2_1Script = preload("res://tests/test_m2_1.gd")

func _init() -> void:
	print("Initializing test runner...")
	var suite1 = TestM1Script.new()
	var success1: bool = suite1.run_all()

	var suite2 = TestM1_1Script.new()
	var success2: bool = suite2.run_all()

	var suite3 = TestM2Script.new()
	var success3: bool = suite3.run_all()

	var suite4 = TestM2_1Script.new()
	var success4: bool = suite4.run_all()

	if success1 and success2 and success3 and success4:
		print("==================================================")
		print("ALL MILESTONE 1, 1.1, 2 AND 2.1 TESTS PASSED SUCCESSFULLY!")
		print("==================================================")
		quit(0)
	else:
		printerr("SOME TESTS FAILED!")
		quit(1)

