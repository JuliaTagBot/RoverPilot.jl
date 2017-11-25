### Some playtime with the little guys Rover2.
### REF: http://blog.leahhanson.us/post/julia/julia-calling-python.html

# Installs
# Pkg.add("Images")
# Pkg.add("ImageView")
# Pkg.add("PyCall")
# Pkg.add("CloudGraphs")
# Pkg.add("ProgressMeter")
# Pkg.add("JSON")
# Pkg.add("Unmarshal")

using PyCall
using FileIO
using CloudGraphs
using Caesar, IncrementalInference, RoME
using KernelDensityEstimate
# include("ExtensionMethods.jl")

include("./entities/RoverPose.jl")
include("./entities/SystemConfig.jl")
include("./service/KafkaService.jl")

# Allow the local directory to be used
cd("/home/gears/roverlock");
unshift!(PyVector(pyimport("sys")["path"]), "")

# Read the configuration
sysConfig = readSystemConfigFile(dirname(Base.source_path()) *"/config/systemconfig.json")
sysConfig.sessionId = sysConfig.sessionPrefix * "_" * string(Base.Random.uuid1())[1:8] #Name+SHA

function sendCloudGraphsPose(pose::RoverPose, sysConfig::SystemConfig, fg::IncrementalInference.FactorGraph, kafkaService::KafkaService)
    # Get from sysConfig
    Podo=diagm([0.1;0.1;0.005]) # TODO ASK: Noise?
    N=100
    lastPoseVertex, factorPose = addOdoFG!(fg, poseIndex(pose), odoDiff(pose), Podo, N=N, labels=["POSE", sysConfig.botId])
    # Now send the images.
    # TODO WIP HERE
end

shouldRun = true
function juliaDataLoop(sysConfig::SystemConfig, rover, fg::IncrementalInference.FactorGraph, kafkaService::KafkaService)
    # Initialize the factor graph and insert first pose.
    lastPoseVertex = initFactorGraph!(fg, labels=[sysConfig.botId])

    # Make the initial pose, assuming start pose is 0,0,0 - setting the time to now.
    curPose = RoverPose()
    curPose.timestamp = Base.Dates.datetime2unix(now())
    # Bump it to x2 because we already have x1 (curPose = proposed pose, not saved yet)
    curPose.poseIndex = 2

    println("[Julia Data Loop] Should run = $shouldRun");
    while shouldRun
        # Update the data acquisition
        rover[:iterateDataProcessor]()
        # Check length of queue
        # println("[Julia Data Loop] Image frame count = $frameCount");
        while rover[:getRoverStateCount]() > 0
            roverState = rover[:getRoverState]()
            append!(curPose, roverState, sysConfig.botConfig.maxImagesPerPose)
            println(curPose)
            if (isPoseWorthy(curPose))
                print("Promoting Pose to CloudGraphs!")
                @time sendCloudGraphsPose(curPose, sysConfig, fg, kafkaService)
                curPose = RoverPose(curPose) # Increment pose
            end
        end
    end
    print("[Julia Data Loop] I'm out!");
end

# Connect to CloudGraphs
# TODO - convert this type to a struct already!
configuration = CloudGraphs.CloudGraphConfiguration("localhost", 7474, "neo4j", "neo5j", "localhost", 27017, false, "", "");
cloudGraph = connect(configuration);
conn = cloudGraph.neo4j.connection;
# register types of interest in CloudGraphs
registerGeneralVariableTypes!(cloudGraph)
Caesar.usecloudgraphsdatalayer!()
println("Current session: $(sysConfig.sessionId)")

# Kafka Initialization - callbacks not used yet.
function sessionMessageCallback(message)
    @show typeof(message)
end
function robotMessageCallback(message)
    @show message
end
kafkaService = KafkaService(sysConfig)
initialize(kafkaService, sessionMessageCallback, robotMessageCallback)

fg = Caesar.initfg(sessionname=sysConfig.sessionId, cloudgraph=cloudGraph)

# Let's do some importing
# Ref: https://github.com/JuliaPy/PyCall.jl/issues/53
roverModule = pyimport("RoverPylot")
rover = roverModule[:PS3Rover](sysConfig.botConfig.deadZoneNorm, sysConfig.botConfig.maxRotSpeed, sysConfig.botConfig.maxTransSpeed)

# Initialize
rover[:initialize]()
# Start the main loop
juliaDataLoop(sysConfig, rover, fg, kafkaService)
