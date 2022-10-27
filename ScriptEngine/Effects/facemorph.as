#include "ScriptEngine/Effects/Base/BaseEffect.as"

/*
    refs:

    https://urho3d.io/documentation/HEAD/_file_formats.html   UMDL binary format


    ideas :


    EFFECT

    add nface parameter
    optimize for 2 faces
    combine with perspective - done
    extract facemodel v0 - done
    multiple shape keys ?  - done
    add debug view - done
    choose facemodel version automatically ! - tried, seems not possible
    use proper semantic for vertex offsets


    SHADERS

    fix edges - done
    hlsl version - done
    try different blur approach

    ADD-ON

    Tangents non complele! - done, added placeholder
    set by default all required params when VK face is on - done
    need to flip horizontal axis - done (double flip performed in urho, which is bad but works fine)
    create preset for keys in mask.json - done
    create all slots (UV, UV2) by default - done
    separate addon only for face morph in blender addon

*/

namespace MaskEngine
{

    class facemorph : BaseEffectImpl
    {

    private
        BaseEffect @faceModelEffect;
    private
        Node @faceModelNode;

    private
        BaseEffect @morphModelEffect;
    private
        Node @morphModelNode;
    private
        AnimatedModel @morphAnimModel;
    private
        StaticModel @morphStatic;

    private
        RenderPath @morphRP;

    private
        Dictionary shapeKeysMap = Dictionary();
    private
        bool debug = false;
    private
        int facemodel_version = 0;
    private
        bool perspective_checked = false;
    private
        bool debug_render_added = false;
    private
        float progress = 1.0;

        bool Init(const JSONValue &effect_desc, BaseEffect @parent) override
        {

            if (!BaseEffectImpl::Init(effect_desc, parent))
            {
                return false;
            }

            if (effect_desc.Contains("debug"))
            {
                debug = effect_desc.Get("debug").GetBool();
            }

            String morphModelFile = "";

            if (effect_desc.Contains("model"))
            {
                morphModelFile = effect_desc.Get("model").GetString();
            }
            else
            {
                log.Error("facemorph : need to specify \"model\" to morph from");
                return false;
            }

            if (!cache.Exists(morphModelFile))
            {
                log.Error("facemorph : model file \"" + morphModelFile + "\" does not exists");
                return false;
            }

            if (effect_desc.Contains("progress"))
            {
                progress = effect_desc.Get("progress").GetFloat();
            }

            String morphModelConfig =
                "{" +
                "\"name\": \"model3d\"," +
                "\"nface\" : " + _faceIdx + "," +
                "\"tag\": \"FaceMorph\"," +
                "\"model\": \"" + morphModelFile + "\"," +
                "\"pass\": \"RenderPaths/FaceMorph.xml\"," +
                "\"material\": {" +
                "\"technique\": \"Techniques/FaceMorph.xml\"" +
                "}," +
                "\"anchor\": \"face\"" +
                "}";

            bool wasSkip;
            @morphModelEffect = CreateEffect("model3d", wasSkip);

            if (morphModelEffect !is null)
            {
                JSONFile @jsonFile = JSONFile();
                jsonFile.FromString(morphModelConfig);

                if (!morphModelEffect.Init(jsonFile.GetRoot(), parent))
                {
                    log.Error("facemorph : cannot create morphModel");
                    return false;
                }
            }
            @morphModelNode = morphModelEffect.GetNode(0);

            // creating animated model to accesss morphs
            morphModelNode.scale = Vector3(1.0, 1.0, 1.0); //! -1
            morphStatic = morphModelNode.GetComponent("StaticModel");
            cache.ReloadResource(morphStatic.model); // model is chached on desktop for some reason
            morphAnimModel = morphModelNode.CreateComponent("AnimatedModel");

            morphAnimModel.updateInvisible = true;
            morphAnimModel.model = morphStatic.model;
            morphAnimModel.lightMask = morphStatic.lightMask;

            morphAnimModel.material = morphStatic.materials[0];
            morphAnimModel.materials[0].cullMode = CULL_CW;
            morphModelNode.RemoveComponent("StaticModel");

            // saving initial vertex data before morphs applied
            // ! move this block to addon
            Geometry @morphGeometry = morphAnimModel.model.GetGeometry(0, 0);
            VertexBuffer @morphVertexBuffer = morphGeometry.vertexBuffers[0];
            Array<VertexElement> morphVertexElements = morphVertexBuffer.elements;

            // Array<VertexElement> morphVertexElements;
            // for (uint i = 0; i <= morphVertexBuffer.elements.length; i++) {

            //     VertexElement elem = morphVertexBuffer.elements[i];
            //     morphVertexElements.Push(elem);
            // }
            // morphVertexElements.Push(VertexElement(TYPE_VECTOR4, SEM_TANGENT));
            // morphVertexBuffer.SetSize(morphVertexBuffer.vertexCount, morphVertexElements);

            VectorBuffer morphVectorVertexBuffer = morphVertexBuffer.GetData();
            IndexBuffer @morphIndexBuffer = morphGeometry.indexBuffer;

            for (uint i = 0; i < morphVertexBuffer.vertexCount; i++)
            {
                uint morphOffset = i * morphVertexBuffer.vertexSize;
                // writing base position to iNormal
                morphVectorVertexBuffer.Seek(morphOffset);
                Vector3 basePos = morphVectorVertexBuffer.ReadVector3();
                morphVectorVertexBuffer.Seek(morphOffset + 40); // !iTangent
                morphVectorVertexBuffer.WriteVector4(Vector4(basePos.x, basePos.y, basePos.z, 1.0));
            }
            morphVertexBuffer.SetData(morphVectorVertexBuffer);

            // creating map for shape keys to it's indexes
            if (debug)
                Print("Keys for model : " + morphModelFile);
            for (uint i = 0; i < morphAnimModel.numMorphs; i++)
            {
                String name = morphAnimModel.morphNames[i];
                shapeKeysMap.Set(name, i);
                if (debug)
                    Print("key : " + name + ", index = " + i);
            }

            // apply shape keys weights
            if (effect_desc.Contains("keys"))
            {
                JSONValue keys = effect_desc.Get("keys");
                if (!keys.isArray)
                {
                    log.Error("facemorph : \"keys\" shoud be array");
                }

                for (uint i = 0; i < keys.size; i++)
                {
                    JSONValue keyJSON = keys[i];
                    String key = keyJSON.Get("name").GetString();
                    float weight = keyJSON.Get("weight").GetFloat();

                    SetMorphWeightByName(key, weight);
                }
            }
            else
            {
                log.Error("facemorph : \"keys\" are missing");
                return false;
            }

            SetProgress(progress);

            // trying to guess facemodel_version from vertex count
            if (morphVertexBuffer.vertexCount == 1572)
            {
                facemodel_version = 0;
            }
            else if (morphVertexBuffer.vertexCount == 160)
            {
                facemodel_version = 1;
            }
            else
            {
                log.Error("facemorph : vertex count for model " + morphModelFile + " doesn't match with any facemodel_version : " + morphVertexBuffer.vertexCount);
                return false;
            }

            int global_facemodel_version = GetGlobalVar(FACEMODEL_VERSION).GetInt();

            if (global_facemodel_version != facemodel_version)
            {
                log.Error("facemorph : facemodel_version of model " + morphModelFile + " is facemodel_version" + facemodel_version + ", but mask.json specifies facemodel_version" + global_facemodel_version);
                return false;
            }
            //  Creating white face as a donor of vertex data
            String faceModelConfig =
                "{" +
                "\"name\": \"facemodel\"," +
                "\"nface\" : " + _faceIdx + "," +
                "\"eyes\": true," +
                "\"pass\" : \"same\"," +
                "\"mouth\": true," +
                "\"texture\": { " +
                "\"MatDiffColor\": [1.0, 1.0, 1.0, 1.0] " +
                "}" +
                "}";

            @faceModelEffect = CreateEffect("facemodel", wasSkip);

            if (faceModelEffect !is null)
            {
                JSONFile @jsonFile = JSONFile();
                jsonFile.FromString(faceModelConfig);

                if (!faceModelEffect.Init(jsonFile.GetRoot(), parent))
                {

                    log.Error("facemorph : cannot create faceModel");
                    return false;
                }
            }

            @faceModelNode = faceModelEffect.GetNode(0);

            if (debug)
            {
                // recompile shader with DEBUG
                for (uint i = 0; i < morphStatic.numGeometries; i++)
                {
                    morphAnimModel.materials[0].techniques[0].passes[0].vertexShaderDefines += " DEBUG";
                    morphAnimModel.materials[0].techniques[0].passes[0].pixelShaderDefines += " DEBUG";
                }

                // show facemodel version
                Print("Facemodel version used : facemodel" + facemodel_version);

                // checking vertex information
                Print("vert count = " + morphVertexBuffer.vertexCount);
                Print("ind count = " + morphIndexBuffer.indexCount);

                Print("Reading semantics for morph.");
                Print("Number vertex elements : " + morphVertexElements.length);
                for (uint i = 0; i < morphVertexElements.length; i++)
                {
                    VertexElement element = morphVertexElements[i];
                    Print("    elem " + i + ", semantic : " + element.semantic + ", type : " + element.type + ", offset : " + element.offset);
                }
            }

            SubscribeToEvent("Update", "HandleUpdate");

            AddTags(effect_desc, morphModelNode);

            return true;
        }

        void HandleUpdate(StringHash eventType, VariantMap &eventData)
        {

            UpdateMorphModel();
            UpdateForPerspective();
            UpdateDebugRender();
        }

        void UpdateMorphModel()
        {
            // morphNode.enabled = false;

            StaticModel @faceStatic = faceModelNode.GetComponent("StaticModel");
            if (faceStatic is null)
                return;

            Geometry @morphGeometry = morphAnimModel.model.GetGeometry(0, 0);
            Geometry @faceGeometry = faceStatic.model.GetGeometry(0, 0);

            VertexBuffer @morphVertexBuffer = morphGeometry.vertexBuffers[0];
            VectorBuffer morphVectorVertexBuffer = morphVertexBuffer.GetData();
            IndexBuffer @morphIndexBuffer = morphGeometry.indexBuffer;
            VectorBuffer morphVectorIndexBuffer = morphIndexBuffer.GetData();

            VertexBuffer @faceVertexBuffer = faceGeometry.vertexBuffers[0];
            VectorBuffer faceVectorVertexBuffer = faceVertexBuffer.GetData();
            IndexBuffer @faceIndexBuffer = faceGeometry.indexBuffer;
            VectorBuffer faceVectorIndexBuffer = faceIndexBuffer.GetData();

            // updating face vertices
            for (uint i = 0; i < morphVertexBuffer.vertexCount; i++)
            {
                uint j = i;
                if (facemodel_version == 0)
                {
                    // magic number !!!
                    if (i >= 1318)
                    {
                        j = i + 1;
                    }
                }
                uint morphOffset = i * morphVertexBuffer.vertexSize;
                uint faceOffset = j * faceVertexBuffer.vertexSize;

                // ! use proper semantic offsets

                faceVectorVertexBuffer.Seek(faceOffset);
                Vector3 facePos = faceVectorVertexBuffer.ReadVector3();
                faceVectorVertexBuffer.Seek(faceOffset + 12);
                Vector3 faceNormal = faceVectorVertexBuffer.ReadVector3();
                faceNormal.Normalize();

                // vert color
                // morphVectorVertexBuffer.Seek(morphOffset + 24);
                // morphVectorVertexBuffer.WriteUByte(uint8(faceNormal.x * 255));
                // morphVectorVertexBuffer.WriteUByte(uint8(faceNormal.y * 255));
                // morphVectorVertexBuffer.WriteUByte(uint8(faceNormal.z * 255));
                // morphVectorVertexBuffer.WriteUByte(uint8(255));

                // morphVectorVertexBuffer.WriteVector4(Vector4(faceNormal, 1.0));
                morphVectorVertexBuffer.Seek(morphOffset + 12);
                morphVectorVertexBuffer.WriteVector3(faceNormal);

                // using uv0 and uv1 to pass vec3  to shader
                morphVectorVertexBuffer.Seek(morphOffset + 24);
                morphVectorVertexBuffer.WriteVector2(Vector2(-facePos.x, facePos.y)); // ! x is flipped
                morphVectorVertexBuffer.Seek(morphOffset + 32);
                morphVectorVertexBuffer.WriteVector2(Vector2(facePos.z, 1.0));
            }

            morphVertexBuffer.SetData(morphVectorVertexBuffer);

            faceModelNode.enabled = false;
            Matrix4 faceInvMatrix = faceModelNode.worldTransform.Inverse().ToMatrix4().Transpose();
            morphAnimModel.materials[0].shaderParameters["FaceInvMatrix"] = Variant(faceInvMatrix);
        }

        void UpdateForPerspective()
        {
            // if mask uses perspective, need to update render pipeline
            // this should be  done after perspective init
            // should be done only once
            if (perspective_checked)
                return;
            bool perspective_enabled = false;
            RenderPath @morph2DRP;

            for (uint i = 0; i < renderer.numViewports; i++)
            {
                Viewport @viewport = renderer.viewports[i];
                RenderPath @rp = viewport.renderPath;
                for (uint j = 0; j < rp.numRenderTargets; j++)
                {
                    RenderTargetInfo rt = rp.renderTargets[j];
                    if (rt.name == "PerspectiveTempRT")
                    {
                        perspective_enabled = true;
                    }
                }

                for (uint j = 0; j < rp.numCommands; j++)
                {
                    RenderPathCommand command = rp.commands[j];
                    if (command.tag.StartsWith("3dStartFinish;FaceMorph"))
                    {
                        @morphRP = renderer.viewports[i].renderPath;
                        @morph2DRP = renderer.viewports[Min(i + 1, renderer.numViewports - 1)].renderPath;
                    }
                }
            }

            if (perspective_enabled)
            {

                if (morph2DRP is null)
                {
                    perspective_checked = true;
                    return;
                }

                for (uint i = morph2DRP.numCommands - 1; i > 0; i--)
                {
                    RenderPathCommand morphCommand = morph2DRP.commands[i];
                    // log.Error(morphCommand.tag);
                    if (morphCommand.tag.Contains("FaceMorph"))
                    {
                        // log.Error(i);
                        morph2DRP.RemoveCommand(i);
                        morphRP.InsertCommand(2, morphCommand);
                    }
                }
            }

            if (debug)
            {
                PrintRenderDebug();
            }

            perspective_checked = true;
        }

        void UpdateDebugRender()
        {
            if (debug_render_added || !debug)
                return;

            // modifying render path to chech some debug info

            morphRP.SetEnabled("Blur", false);
            morphRP.SetEnabled("Warp;FaceMorph", false);

            // showing facemodel to viewport
            for (uint i = 1; i < morphRP.numCommands; i++)
            {
                RenderPathCommand command = morphRP.commands[i];

                if (command.tag.StartsWith("3dStartFinish"))
                {
                    // command.enabled = false;
                    command.outputNames[0] = "viewport";
                    morphRP.RemoveCommand(i);
                    morphRP.InsertCommand(i, command);
                }
            }

            debug_render_added = true;
        }

        void PrintRenderDebug()
        {

            for (uint j = 0; j < renderer.numViewports; j++)
            {
                RenderPath @rp = renderer.viewports[j].renderPath;
                Print("\n\n");
                Print("RenderPath " + j + "====================================");
                for (uint i = 0; i < rp.numCommands; i++)
                {
                    RenderPathCommand command = rp.commands[i];
                    Print("--------------------");
                    Print("pass " + command.pass + " = " + Variant(i).ToString() + ", tag = " + command.tag);

                    Print("");
                    Print("Texture inputs: ");
                    Print("");
                    for (TextureUnit k = TU_DIFFUSE; k < MAX_TEXTURE_UNITS; k++)
                    {
                        String textureUnitStr = GetTextureUnitName(k);
                        String name = command.get_textureNames(k);
                        if (name != "")
                            Print("  " + textureUnitStr + " = " + name);
                    }

                    Print("");
                    Print("Texture outputs: ");

                    for (TextureUnit k = TU_DIFFUSE; k < MAX_TEXTURE_UNITS; k++)
                    {
                        String textureUnitStr = GetTextureUnitName(k);
                        String name = command.get_outputNames(k);
                        if (name != "")
                            Print("  " + textureUnitStr + " = " + name);
                    }

                    Print("");
                    Print("  psdef = " + command.pixelShaderDefines);
                    Print("  vsdef = " + command.vertexShaderDefines);
                }

                Print("");
                Print("RenderTargets:");
                for (uint i = 0; i < rp.numRenderTargets; i++)
                {
                    RenderTargetInfo rt = rp.renderTargets[i];
                    Print("  " + i + " name = " + rt.name + ", tag = " + rt.tag);
                }
            }
            log.Error("========================");
        }

        String GetName() override
        {
            return "facemorph";
        }

        void SetProgress(float new_progress)
        {
            morphAnimModel.materials[0].shaderParameters["Progress"] = Variant(new_progress);
        }

        bool SetMorphWeightByName(String key, float weight)
        {
            uint index;
            if (!shapeKeysMap.Exists(key))
            {
                log.Warning("facemorph/SetKey : key " + key + " does not exist");
                return false;
            }
            shapeKeysMap.Get(key, index);
            morphAnimModel.SetMorphWeight(index, weight);
            if (debug)
                Print("    key : " + key + ", weight = " + weight + ", index = " + index);
            return true;
        }
    }

}